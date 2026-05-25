import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';

import 'persistence/node_db.dart';
import 'agent/agent_runner.dart';
import 'agent/pi_capabilities.dart';
import 'agent/pi_rpc_client.dart';
import 'agent/pi_runner.dart';
import 'agent/pi_session_index.dart';

typedef AgentRunnerFactory = AgentRunner? Function(String agentType);

/// MobilePi 物理机守护进程 — Hub-connected daemon 模式
///
/// 默认主动连接 Hub，由 Hub 负责 Client ↔ Daemon 路由。
/// 也可启动本地直连 WebSocket Server，使用同一套协议方便集成测试。
/// 处理心跳 (ping/pong) 与统一交互协议。
class _SessionWatchState {
  _SessionWatchState({
    required this.taskId,
    required this.sessionPath,
    this.offset = 0,
  });

  final String taskId;
  final String sessionPath;
  int offset;
  String partial = '';
  final Set<String> recentFingerprints = <String>{};
  StreamSubscription<FileSystemEvent>? subscription;
}

class NodeDaemon {
  late final String nodeId;
  late final String hostname;
  late final List<String> agents;

  final int port;
  final String? hubUrl;
  final String? tenantKey;
  final Logger _logger = Logger('NodeDaemon');
  HttpServer? _server;
  WebSocketChannel? _hubChannel;
  Completer<void>? _shutdownCompleter;
  Timer? _reconnectTimer;
  bool _stopping = false;
  final Map<String, WebSocketChannel> _clients = {};

  final String? dbPath;
  final AgentRunnerFactory _runnerFactory;
  NodeDatabase? _db;
  final Map<String, AgentRunner> _activeRunners = {};
  final Map<String, StreamSubscription<AgentEvent>> _runnerSubs = {};
  final Map<String, String> _activeTaskIdsByInstance = {};
  final Map<String, String> _taskInstanceIds = {};
  final Map<String, String> _taskModels = {};
  final Map<String, _SessionWatchState> _sessionWatchesByTask = {};
  PiCapabilities _piCapabilities = PiCapabilities.empty;
  DateTime? _piCapabilitiesLoadedAt;
  Future<void>? _piCapabilitiesRefresh;

  static const _defaultPiInstanceId = 'default';
  static const _piCapabilityCacheTtl = Duration(seconds: 20);

  NodeDaemon({
    this.port = 9000,
    this.hubUrl,
    this.tenantKey,
    this.dbPath,
    AgentRunnerFactory? runnerFactory,
  }) : _runnerFactory = runnerFactory ?? _defaultRunnerFactory;

  static AgentRunner? _defaultRunnerFactory(String agentType) =>
      switch (agentType) {
        'pi' => PiRunner(),
        _ => null,
      };

  Future<void> start() async {
    // 1. 初始化 SQLite
    _db = NodeDatabase(dbPath: dbPath);
    final info = await _db!.initialize();
    nodeId = info['nodeId']!;
    hostname = info['hostname']!;

    // 2. MobilePi is now a Pi-only adapter. Host multiplicity is represented by
    // separate Node daemons; per-host multiplicity is represented by instanceId.
    agents = const ['pi'];
    _logger.info(
      'event=node.started ${logFields({'nodeId': nodeId, 'hostname': hostname, 'agents': agents.join(',')})}',
    );

    if (hubUrl != null && hubUrl!.trim().isNotEmpty) {
      if (tenantKey == null || tenantKey!.trim().isEmpty) {
        throw ArgumentError.value(
          tenantKey,
          'tenantKey',
          'is required when connecting to Hub',
        );
      }
      // Hub 注册前需要完整摘要。
      _piCapabilities = await _loadPiCapabilities();
      await _startHubClient(normalizeHubUrl(hubUrl!));
      return;
    }

    unawaited(
      _loadPiCapabilities().then((capabilities) {
        _piCapabilities = capabilities;
      }),
    );
    await _startDirectServer();
  }

  Future<void> _startDirectServer() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _logger.info(
      'event=direct_server.started ${logFields({'address': '0.0.0.0', 'port': port})}',
    );

    await for (final request in _server!) {
      if (request.uri.path == '/ws') {
        final socket = await WebSocketTransformer.upgrade(request);
        final channel = IOWebSocketChannel(socket);
        final clientId = 'client-${const Uuid().v4()}';
        _clients[clientId] = channel;

        _logger.info(
          'event=client.connected ${logField('clientId', clientId)}',
        );

        channel.stream.listen(
          (data) => _handleMessage(clientId, channel, data),
          onDone: () => _removeClient(clientId),
          onError: (e) {
            _logger.warning(
              'event=client.error ${logField('clientId', clientId)}',
              e,
            );
            _removeClient(clientId);
          },
        );
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    }
  }

  Future<void> _startHubClient(String normalizedHubUrl) async {
    _shutdownCompleter = Completer<void>();
    await _connectHub(normalizedHubUrl);
    return _shutdownCompleter!.future;
  }

  Future<void> _connectHub(String normalizedHubUrl) async {
    if (_stopping) return;
    _logger.info(
      'event=hub.connect_start ${logField('hubUrl', normalizedHubUrl)}',
    );

    try {
      final channel = WebSocketChannel.connect(Uri.parse(normalizedHubUrl));
      _hubChannel = channel;
      channel.stream.listen(
        (data) => _handleMessage('hub', channel, data),
        onDone: () => _handleHubDisconnected(normalizedHubUrl, channel),
        onError: (Object e) {
          _logger.warning(
            'event=hub.connection_error ${logField('hubUrl', normalizedHubUrl)}',
            e,
          );
          _handleHubDisconnected(normalizedHubUrl, channel);
        },
      );
      await _sendNodeHello(channel);
    } catch (e, st) {
      _logger.warning(
        'event=hub.connect_failed ${logField('hubUrl', normalizedHubUrl)}',
        e,
        st,
      );
      _scheduleHubReconnect(normalizedHubUrl);
    }
  }

  void _handleHubDisconnected(
    String normalizedHubUrl,
    WebSocketChannel channel,
  ) {
    if (_stopping) return;
    _logger.warning(
      'event=hub.disconnected ${logField('hubUrl', normalizedHubUrl)}',
    );
    if (identical(_hubChannel, channel)) {
      _hubChannel = null;
    }
    _scheduleHubReconnect(normalizedHubUrl);
  }

  void _scheduleHubReconnect(String normalizedHubUrl) {
    if (_stopping || _reconnectTimer?.isActive == true) return;
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      _reconnectTimer = null;
      unawaited(_connectHub(normalizedHubUrl));
    });
    _logger.info(
      'event=hub.reconnect_scheduled ${logFields({'hubUrl': normalizedHubUrl, 'delayMs': 2000})}',
    );
  }

  Future<void> stop() async {
    _stopping = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    for (final watch in _sessionWatchesByTask.values) {
      watch.subscription?.cancel();
    }
    _sessionWatchesByTask.clear();
    for (final subscription in _runnerSubs.values) {
      await subscription.cancel();
    }
    _runnerSubs.clear();
    for (final runner in _activeRunners.values) {
      await runner.abort();
    }
    _activeRunners.clear();
    for (final channel in _clients.values) {
      await channel.sink.close();
    }
    _clients.clear();
    await _hubChannel?.sink.close();
    _hubChannel = null;
    await _server?.close();
    _db?.close();
    if (_shutdownCompleter != null && !_shutdownCompleter!.isCompleted) {
      _shutdownCompleter!.complete();
    }
    _logger.info('event=node.stopped ${logField('nodeId', nodeId)}');
  }

  void _removeClient(String clientId) {
    _clients.remove(clientId);
    _logger.info('event=client.disconnected ${logField('clientId', clientId)}');
  }

  void _handleMessage(String clientId, WebSocketChannel channel, dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      final message = MobilePiMessage.fromJson(json);
      _logger.fine(
        'event=ws.receive ${logField('peerId', clientId)} ${summarizeMessage(message)}',
      );

      switch (message.type) {
        case MessageType.ping:
          _sendPong(channel, message.messageId, message.from);
          break;
        case MessageType.hello:
        case MessageType.resume:
        case MessageType.command:
        case MessageType.query:
          _handleProtocolMessage(clientId, channel, message);
          break;
        default:
          _logger.warning(
            'event=ws.unhandled_message ${logField('peerId', clientId)} ${summarizeMessage(message)}',
          );
      }
    } catch (e, st) {
      _logger.warning(
        'event=ws.message_error ${logField('peerId', clientId)}',
        e,
        st,
      );
    }
  }

  void _handleProtocolMessage(
    String peerId,
    WebSocketChannel channel,
    MobilePiMessage message,
  ) {
    switch (message.type) {
      case MessageType.hello:
        unawaited(_sendResumeResponse(channel, message, includeEvents: false));
        break;
      case MessageType.resume:
        unawaited(_sendResumeResponse(channel, message));
        break;
      case MessageType.command:
        _handleProtocolCommand(peerId, channel, message);
        break;
      case MessageType.query:
        unawaited(_handleProtocolQuery(channel, message));
        break;
      default:
        _logger.warning(
          'event=protocol.unhandled ${logField('peerId', peerId)} ${summarizeMessage(message)}',
        );
    }
  }

  void _sendPong(WebSocketChannel channel, String messageId, String from) {
    final response = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: nodeId,
      to: from,
      type: MessageType.pong,
      payload: {},
    );
    channel.sink.add(jsonEncode(response.toJson()));
  }

  Future<void> _sendNodeHello(WebSocketChannel channel) async {
    final message = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: 'node:$nodeId',
      to: 'hub',
      type: MessageType.hello,
      payload: {
        ..._nodeSummaryPayload(),
        ProtocolPayloadKeys.tenantKey: tenantKey!.trim(),
      },
    );
    _logger.info('event=node.hello_send ${summarizeMessage(message)}');
    channel.sink.add(jsonEncode(message.toJson()));
  }

  Map<String, dynamic> _nodeSummaryPayload() {
    final capabilities = _getPiCapabilities();
    final payload = <String, dynamic>{
      ProtocolPayloadKeys.nodeId: nodeId,
      ProtocolPayloadKeys.hostname: hostname,
      ProtocolPayloadKeys.platform: Platform.operatingSystem,
      ProtocolPayloadKeys.agents: agents,
      ProtocolPayloadKeys.online: true,
      ProtocolPayloadKeys.piModels: capabilities.models
          .map((model) => model.toJson())
          .toList(),
      ProtocolPayloadKeys.piSlashCommands: capabilities.slashCommands
          .map((command) => command.toJson())
          .toList(),
      ProtocolPayloadKeys.piInstances: _piInstances()
          .map((instance) => instance.toJson())
          .toList(),
      if (capabilities.state != null)
        ProtocolPayloadKeys.piState: capabilities.state,
      ProtocolPayloadKeys.piMessages: capabilities.messages,
      ProtocolPayloadKeys.piSessions: capabilities.sessions
          .map((session) => session.toJson())
          .toList(),
    };
    if (capabilities.defaultModel != null) {
      payload[ProtocolPayloadKeys.piDefaultModel] = capabilities.defaultModel;
    }
    return payload;
  }

  Future<void> _sendResumeResponse(
    WebSocketChannel channel,
    MobilePiMessage request, {
    bool includeEvents = true,
  }) async {
    final cursors = _parseCursorMap(
      request.payload[ProtocolPayloadKeys.cursors],
    );
    final events = includeEvents
        ? _db!
              .eventsAfter(cursors)
              .map((event) => event.toProtocolPayload())
              .toList()
        : const <Map<String, dynamic>>[];
    final payload = <String, dynamic>{
      ProtocolPayloadKeys.responseTo: request.messageId,
      ProtocolPayloadKeys.nodeSummary: _nodeSummaryPayload(),
      ProtocolPayloadKeys.events: events,
      ProtocolPayloadKeys.truncatedStreams: const <Map<String, dynamic>>[],
    };
    final response = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: 'node:$nodeId',
      to: 'client',
      type: MessageType.response,
      payload: payload,
    );
    _sendJson(channel, response.toJson());
  }

  void _handleProtocolCommand(
    String peerId,
    WebSocketChannel channel,
    MobilePiMessage message,
  ) {
    final commandType = message.payload[ProtocolPayloadKeys.commandType]
        ?.toString();
    if (commandType == null || commandType.isEmpty) {
      _logger.warning(
        'event=command.reject reason=missing_command_type ${summarizeMessage(message)}',
      );
      _sendProtocolError(channel, message, 'missing_command_type');
      return;
    }

    final requestId =
        message.payload[ProtocolPayloadKeys.requestId]?.toString() ??
        message.messageId;
    final taskId = message.payload['taskId']?.toString();
    final existingResult = _db!.commandResult(requestId);
    if (existingResult != null) {
      _logger.info(
        'event=command.duplicate ${logFields({'requestId': shortId(requestId), 'command': commandType, 'taskId': shortId(taskId)})}',
      );
      _sendProtocolResponse(channel, message, existingResult);
      return;
    }
    final inserted = _db!.insertCommandRequest(
      requestId: requestId,
      commandType: commandType,
      taskId: taskId,
    );
    if (!inserted) {
      _logger.info(
        'event=command.already_inserted ${logFields({'requestId': shortId(requestId), 'command': commandType, 'taskId': shortId(taskId)})}',
      );
      _sendProtocolResponse(channel, message, const <String, dynamic>{});
      return;
    }

    _logger.info(
      'event=command.accepted ${logFields({'peerId': peerId, 'requestId': shortId(requestId), 'command': commandType, 'taskId': shortId(taskId)})}',
    );

    switch (commandType) {
      case 'cursor.ack':
        _db!.completeCommandRequest(requestId, {'acknowledged': true});
        _sendProtocolResponse(channel, message, {'acknowledged': true});
        break;
      case 'task.create':
        final effectiveTaskId = taskId == null || taskId.isEmpty
            ? const Uuid().v4()
            : taskId;
        _handleTaskCommand(
          peerId,
          channel,
          MobilePiMessage(
            messageId: message.messageId,
            from: message.from,
            to: message.to,
            type: MessageType.command,
            payload: {
              ...message.payload,
              'taskId': effectiveTaskId,
              'agentType': message.payload['agentType']?.toString() ?? 'pi',
              'prompt': message.payload['prompt']?.toString() ?? '',
            },
          ),
        );
        _db!.completeCommandRequest(requestId, {
          'taskId': effectiveTaskId,
          ProtocolPayloadKeys.streamId: _taskStreamId(effectiveTaskId),
        });
        _sendProtocolResponse(channel, message, {
          'taskId': effectiveTaskId,
          ProtocolPayloadKeys.streamId: _taskStreamId(effectiveTaskId),
        });
        break;
      case 'task.follow_up':
        _handleFollowUpCommand(
          peerId,
          channel,
          MobilePiMessage(
            messageId: message.messageId,
            from: message.from,
            to: message.to,
            type: MessageType.command,
            payload: {
              ...message.payload,
              'message':
                  message.payload['message']?.toString() ??
                  message.payload['prompt']?.toString() ??
                  '',
            },
          ),
        );
        _db!.completeCommandRequest(requestId, {'taskId': taskId});
        break;
      case 'task.steer':
        _handleSteerCommand(
          peerId,
          channel,
          MobilePiMessage(
            messageId: message.messageId,
            from: message.from,
            to: message.to,
            type: MessageType.command,
            payload: {
              ...message.payload,
              'message':
                  message.payload['message']?.toString() ??
                  message.payload['prompt']?.toString() ??
                  '',
            },
          ),
        );
        _db!.completeCommandRequest(requestId, {'taskId': taskId});
        break;
      case 'task.panic':
        _handlePanic(
          peerId,
          channel,
          MobilePiMessage(
            messageId: message.messageId,
            from: message.from,
            to: message.to,
            type: MessageType.command,
            payload: message.payload,
          ),
        );
        _db!.completeCommandRequest(requestId, {'taskId': taskId});
        break;
      case 'directory.create':
        unawaited(_handleCreateDirectoryRequest(peerId, channel, message));
        _db!.completeCommandRequest(requestId, {'accepted': true});
        break;
      default:
        _sendProtocolError(channel, message, 'unknown_command_type');
    }
  }

  Future<void> _handleProtocolQuery(
    WebSocketChannel channel,
    MobilePiMessage message,
  ) async {
    final queryType = message.payload[ProtocolPayloadKeys.commandType]
        ?.toString();
    switch (queryType) {
      case 'node.summary':
        _logger.info('event=query.node_summary ${summarizeMessage(message)}');
        _sendProtocolResponse(channel, message, {
          ProtocolPayloadKeys.nodeSummary: _nodeSummaryPayload(),
        });
        break;
      case 'messages.list':
        await _handleSessionMessagesRequest('client', channel, message);
        break;
      case 'directory.browse':
        await _handleBrowseDirectoryRequest('client', channel, message);
        break;
      default:
        _logger.warning(
          'event=query.reject reason=unknown_query_type ${summarizeMessage(message)}',
        );
        _sendProtocolError(channel, message, 'unknown_query_type');
    }
  }

  void _sendProtocolResponse(
    WebSocketChannel channel,
    MobilePiMessage request,
    Map<String, dynamic> payload,
  ) {
    final response = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: 'node:$nodeId',
      to: 'client',
      type: MessageType.response,
      payload: {ProtocolPayloadKeys.responseTo: request.messageId, ...payload},
    );
    _sendJson(channel, response.toJson());
  }

  void _sendProtocolError(
    WebSocketChannel channel,
    MobilePiMessage request,
    String code,
  ) {
    final response = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: 'node:$nodeId',
      to: 'client',
      type: MessageType.error,
      payload: {
        ProtocolPayloadKeys.responseTo: request.messageId,
        'code': code,
      },
    );
    _sendJson(channel, response.toJson());
  }

  void _handleTaskCommand(
    String clientId,
    WebSocketChannel channel,
    MobilePiMessage message,
  ) {
    final payload = message.payload;
    final taskId = payload['taskId'] as String? ?? const Uuid().v4();
    final agentType = payload['agentType'] as String? ?? 'pi';
    final model = payload[ProtocolPayloadKeys.model]?.toString();
    final projectPath = payload[ProtocolPayloadKeys.projectPath]?.toString();
    final instanceId =
        payload[ProtocolPayloadKeys.piInstanceId]?.toString() ??
        _defaultPiInstanceId;
    final prompt = payload['prompt'] as String? ?? '';

    if (prompt.isEmpty) {
      _logger.warning(
        'event=task.create_rejected reason=missing_prompt ${summarizeMessage(message)}',
      );
      return;
    }

    // 同一 Pi instance 同时只能跑一个前台 turn；其他 instance 不受影响。
    final activeRunner = _activeRunners[instanceId];
    if (activeRunner != null) {
      _logger.info(
        'event=runner.replace ${logFields({'instanceId': instanceId, 'previousTaskId': shortId(_activeTaskIdsByInstance[instanceId]), 'taskId': shortId(taskId)})}',
      );
      _runnerSubs.remove(instanceId)?.cancel();
      unawaited(activeRunner.abort());
      _activeRunners.remove(instanceId);
    }

    _activeTaskIdsByInstance[instanceId] = taskId;
    _taskInstanceIds[taskId] = instanceId;
    if (model != null && model.isNotEmpty) {
      _taskModels[taskId] = model;
    }

    final title = prompt.length > 80 ? '${prompt.substring(0, 80)}...' : prompt;
    _db!.upsertTask(
      taskId: taskId,
      streamId: _taskStreamId(taskId),
      agentType: agentType,
      title: title,
      status: 'running',
      projectPath: projectPath,
      model: model,
    );
    _sendTaskEvent(channel, taskId, 'task.created', {
      'taskId': taskId,
      ProtocolPayloadKeys.title: title,
      ProtocolPayloadKeys.projectPath: projectPath,
      'agentType': agentType,
      ProtocolPayloadKeys.model: model,
      ProtocolPayloadKeys.piInstanceId: instanceId,
      'status': 'running',
    });
    _sendTaskEvent(channel, taskId, 'task.started', {
      'taskId': taskId,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'status': 'running',
      ProtocolPayloadKeys.piInstanceId: instanceId,
    });

    // 创建对应的 Runner
    final runner = _runnerFactory(agentType);

    if (runner == null) {
      _logger.warning(
        'event=task.create_rejected reason=unknown_agent ${logFields({'agentType': agentType, 'taskId': shortId(taskId)})}',
      );
      _sendTaskUpdate(
        channel,
        taskId,
        'error',
        streamingText: '未知 Agent: $agentType',
      );
      return;
    }

    _activeRunners[instanceId] = runner;
    _subscribeToRunner(runner, taskId, instanceId, channel);
    runner.start(taskId, prompt, model: model);
    final taskStartedFields = <String, Object?>{
      'taskId': shortId(taskId),
      'agentType': agentType,
      'instanceId': instanceId,
      'promptLength': prompt.length,
    };
    if (model != null) taskStartedFields['model'] = model;
    if (projectPath != null) taskStartedFields['projectPath'] = projectPath;
    _logger.info('event=task.started ${logFields(taskStartedFields)}');
  }

  void _handleSteerCommand(
    String clientId,
    WebSocketChannel channel,
    MobilePiMessage message,
  ) {
    final payload = message.payload;
    final taskId = payload['taskId'] as String?;
    final instanceId = _resolveInstanceId(payload, taskId);
    final activeTaskId = taskId ?? _activeTaskIdsByInstance[instanceId];
    final msg = payload['message'] as String? ?? '';
    final runner = _activeRunners[instanceId];
    if (msg.isEmpty) {
      _logger.warning(
        'event=task.steer_rejected reason=missing_message ${summarizeMessage(message)}',
      );
      return;
    }

    if (runner == null || !runner.isRunning) {
      final sessionPath = payload[ProtocolPayloadKeys.sessionPath]?.toString();
      if (sessionPath != null && sessionPath.isNotEmpty) {
        unawaited(
          _resumeSessionAndPrompt(
            message.from.isEmpty ? clientId : message.from,
            channel,
            instanceId,
            activeTaskId ?? '',
            sessionPath,
            msg,
          ),
        );
        return;
      }
      _logger.warning(
        'event=task.steer_rejected reason=no_active_task ${logFields({'taskId': shortId(activeTaskId), 'instanceId': instanceId, 'hasSessionPath': sessionPath != null && sessionPath.isNotEmpty})}',
      );
      _sendTaskUpdate(
        channel,
        activeTaskId ?? '',
        'error',
        streamingText: '无活跃任务可调校',
      );
      return;
    }

    _logger.info(
      'event=task.steer ${logFields({'taskId': shortId(activeTaskId), 'instanceId': instanceId, 'messageLength': msg.length})}',
    );
    unawaited(
      runner.steer(msg).catchError((Object e, StackTrace st) {
        _logger.warning(
          'event=task.steer_failed ${logFields({'taskId': shortId(activeTaskId), 'instanceId': instanceId})}',
          e,
          st,
        );
        _sendTaskUpdate(
          channel,
          activeTaskId ?? '',
          'error',
          streamingText: '调校失败: $e',
        );
      }),
    );
    _sendTaskUpdate(
      channel,
      activeTaskId ?? '',
      'running',
      streamingText: '⤷ 调校: $msg',
    );
  }

  void _handleFollowUpCommand(
    String clientId,
    WebSocketChannel channel,
    MobilePiMessage message,
  ) {
    final payload = message.payload;
    final taskId = payload['taskId'] as String?;
    final instanceId = _resolveInstanceId(payload, taskId);
    final activeTaskId = taskId ?? _activeTaskIdsByInstance[instanceId];
    final msg = payload['message'] as String? ?? '';
    final runner = _activeRunners[instanceId];
    if (msg.isEmpty) {
      _logger.warning(
        'event=task.follow_up_rejected reason=missing_message ${summarizeMessage(message)}',
      );
      return;
    }

    if (runner == null || !runner.isRunning) {
      final sessionPath = payload[ProtocolPayloadKeys.sessionPath]?.toString();
      if (sessionPath != null && sessionPath.isNotEmpty) {
        unawaited(
          _resumeSessionAndPrompt(
            message.from.isEmpty ? clientId : message.from,
            channel,
            instanceId,
            activeTaskId ?? '',
            sessionPath,
            msg,
          ),
        );
        return;
      }
      _logger.warning(
        'event=task.follow_up_rejected reason=no_active_task ${logFields({'taskId': shortId(activeTaskId), 'instanceId': instanceId, 'hasSessionPath': sessionPath != null && sessionPath.isNotEmpty})}',
      );
      _sendTaskUpdate(
        channel,
        activeTaskId ?? '',
        'error',
        streamingText: '无活跃任务可追加指令',
      );
      return;
    }

    _logger.info(
      'event=task.follow_up ${logFields({'taskId': shortId(activeTaskId), 'instanceId': instanceId, 'messageLength': msg.length})}',
    );
    unawaited(
      runner.followUp(msg).catchError((Object e, StackTrace st) {
        _logger.warning(
          'event=task.follow_up_failed ${logFields({'taskId': shortId(activeTaskId), 'instanceId': instanceId})}',
          e,
          st,
        );
        _sendTaskUpdate(
          channel,
          activeTaskId ?? '',
          'error',
          streamingText: '追加失败: $e',
        );
      }),
    );
    _sendTaskUpdate(
      channel,
      activeTaskId ?? '',
      'running',
      streamingText: '➥ 追加: $msg',
    );
  }

  Future<void> _resumeSessionAndPrompt(
    String clientId,
    WebSocketChannel channel,
    String instanceId,
    String taskId,
    String sessionPath,
    String message,
  ) async {
    final runner = await _resumeSession(
      clientId,
      channel,
      instanceId,
      taskId,
      sessionPath,
    );
    if (runner == null) return;

    _logger.info(
      'event=session.prompt_after_resume ${logFields({'taskId': shortId(taskId), 'instanceId': instanceId, 'sessionPath': sessionPath, 'messageLength': message.length})}',
    );
    try {
      await runner.prompt(message);
      _logger.info(
        'event=session.prompt_sent ${logFields({'taskId': shortId(taskId), 'instanceId': instanceId, 'sessionPath': sessionPath})}',
      );
    } catch (e, st) {
      _logger.warning(
        'event=session.prompt_failed ${logFields({'taskId': shortId(taskId), 'instanceId': instanceId, 'sessionPath': sessionPath})}',
        e,
        st,
      );
      try {
        await runner.abort();
      } catch (abortError) {
        _logger.warning(
          'event=runner.abort_failed reason=resume_prompt_failed ${logFields({'taskId': shortId(taskId), 'instanceId': instanceId})}',
          abortError,
        );
      }
      _activeRunners.remove(instanceId);
      _activeTaskIdsByInstance.remove(instanceId);
      _sendTaskUpdate(channel, taskId, 'error', streamingText: '发送消息失败: $e');
    }
  }

  Future<AgentRunner?> _resumeSession(
    String clientId,
    WebSocketChannel channel,
    String instanceId,
    String taskId,
    String sessionPath,
  ) async {
    final runner = _runnerFactory('pi');
    if (runner == null) {
      _logger.warning(
        'event=session.resume_failed reason=no_pi_runner ${logFields({'taskId': shortId(taskId), 'instanceId': instanceId, 'sessionPath': sessionPath})}',
      );
      _sendTaskUpdate(
        channel,
        taskId,
        'error',
        streamingText: '无法创建 Pi Runner',
      );
      return null;
    }

    _activeRunners[instanceId] = runner;
    _activeTaskIdsByInstance[instanceId] = taskId;
    _taskInstanceIds[taskId] = instanceId;
    _db!.upsertTask(
      taskId: taskId,
      streamId: _taskStreamId(taskId),
      agentType: 'pi',
      title:
          'Pi session ${taskId.length <= 8 ? taskId : taskId.substring(0, 8)}',
      status: 'running',
      sessionPath: sessionPath,
      model: _taskModels[taskId],
    );

    final model = _taskModels[taskId];
    _subscribeToRunner(runner, taskId, instanceId, channel);

    try {
      await runner.resumeSession(taskId, sessionPath, model: model);
      _startSessionWatch(taskId: taskId, sessionPath: sessionPath);
      final resumedFields = <String, Object?>{
        'taskId': shortId(taskId),
        'instanceId': instanceId,
        'sessionPath': sessionPath,
      };
      if (model != null) resumedFields['model'] = model;
      _logger.info('event=session.resumed ${logFields(resumedFields)}');
      _sendTaskUpdate(
        channel,
        taskId,
        'running',
        streamingText: '⤴ 恢复会话并继续...',
      );
      return runner;
    } catch (e, st) {
      _logger.warning(
        'event=session.resume_failed ${logFields({'taskId': shortId(taskId), 'instanceId': instanceId, 'sessionPath': sessionPath})}',
        e,
        st,
      );
      _activeRunners.remove(instanceId);
      _activeTaskIdsByInstance.remove(instanceId);
      _sendTaskUpdate(channel, taskId, 'error', streamingText: '恢复会话失败: $e');
      return null;
    }
  }

  void _startSessionWatch({
    required String taskId,
    required String sessionPath,
  }) {
    final file = File(sessionPath);
    final existing = _sessionWatchesByTask[taskId];
    if (existing != null && existing.sessionPath == sessionPath) return;

    if (existing != null) {
      existing.subscription?.cancel();
    }

    final state = _SessionWatchState(
      taskId: taskId,
      sessionPath: sessionPath,
      offset: file.existsSync() ? file.lengthSync() : 0,
    );
    _sessionWatchesByTask[taskId] = state;

    // Ensure the file exists so we can watch it reliably
    if (!file.existsSync()) {
      try {
        file.createSync(recursive: true);
      } catch (e) {
        _logger.warning('event=session.watch_file_create_failed path=$sessionPath', e);
      }
    }

    try {
      state.subscription = file.watch(events: FileSystemEvent.modify).listen(
        (_) => _onSessionFileChanged(state),
        onError: (Object e) {
          _logger.warning('event=session.watch_error taskId=$taskId path=$sessionPath', e);
        },
      );
      _logger.info('event=session.watch_started taskId=${shortId(taskId)} path=$sessionPath');
    } catch (e) {
      _logger.warning('event=session.watch_setup_failed taskId=$taskId path=$sessionPath', e);
    }
  }

  Future<void> _onSessionFileChanged(_SessionWatchState watch) async {
    if (_stopping) return;
    final file = File(watch.sessionPath);
    if (!file.existsSync()) return;
    final len = file.lengthSync();
    if (len < watch.offset) {
      watch.offset = 0;
      watch.partial = '';
    }
    if (len == watch.offset) return;
    final raf = await file.open();
    try {
      await raf.setPosition(watch.offset);
      final bytes = await raf.read(len - watch.offset);
      watch.offset = len;
      final chunk = watch.partial + utf8.decode(bytes, allowMalformed: true);
      final lines = chunk.split('\n');
      watch.partial = lines.removeLast();
      for (final line in lines) {
        final delta = _extractDeltaFromSessionLine(line);
        if (delta == null || delta.isEmpty) continue;
        final sig = '${watch.taskId}:${delta.hashCode}';
        if (!watch.recentFingerprints.add(sig)) continue;
        if (watch.recentFingerprints.length > 300) {
          watch.recentFingerprints.remove(watch.recentFingerprints.first);
        }
        _broadcastTaskUpdate(
          watch.taskId,
          'running',
          streamingDelta: delta,
        );
      }
    } catch (e, st) {
      _logger.warning('event=session.file_read_error taskId=${watch.taskId}', e, st);
    } finally {
      await raf.close();
    }
  }

  String? _extractDeltaFromSessionLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    try {
      final obj = jsonDecode(trimmed);
      if (obj is! Map) return null;
      if (obj['type']?.toString() != 'message') return null;
      final msg = obj['message'];
      if (msg is! Map) return null;
      if (msg['role']?.toString() != 'assistant') return null;
      final content = msg['content'];
      if (content is! List) return null;
      final parts = <String>[];
      for (final item in content) {
        if (item is Map && item['type']?.toString() == 'text') {
          final text = item['text']?.toString();
          if (text != null && text.isNotEmpty) parts.add(text);
        }
      }
      if (parts.isEmpty) return null;
      return parts.join('\n');
    } catch (_) {
      return null;
    }
  }

  void _broadcastTaskUpdate(
    String taskId,
    String status, {
    String? streamingDelta,
  }) {
    if (_hubChannel != null) {
      _sendTaskUpdate(
        _hubChannel!,
        taskId,
        status,
        streamingDelta: streamingDelta,
      );
      return;
    }
    for (final channel in _clients.values) {
      _sendTaskUpdate(
        channel,
        taskId,
        status,
        streamingDelta: streamingDelta,
      );
    }
  }

  Future<void> _handleSessionMessagesRequest(
    String clientId,
    WebSocketChannel channel,
    MobilePiMessage message,
  ) async {
    final payload = message.payload;
    final sessionPath = payload['sessionPath'] as String?;
    final taskId = payload['taskId']?.toString();
    final limit = payload['limit'] as int? ?? 20;
    final beforeIndex = payload['beforeIndex'] as int?;

    if (sessionPath == null || sessionPath.isEmpty) {
      _logger.warning(
        'event=messages.list_rejected reason=missing_session_path ${summarizeMessage(message)}',
      );
      return;
    }

    _logger.info(
      'event=messages.list ${logFields({'sessionPath': sessionPath, 'taskId': shortId(taskId), 'limit': limit, 'beforeIndex': beforeIndex})}',
    );

    if (taskId != null && taskId.isNotEmpty) {
      _taskInstanceIds.putIfAbsent(taskId, () => _defaultPiInstanceId);
      _db!.upsertTask(
        taskId: taskId,
        streamId: _taskStreamId(taskId),
        agentType: 'pi',
        title: 'Pi session ${taskId.length <= 8 ? taskId : taskId.substring(0, 8)}',
        status: 'running',
        sessionPath: sessionPath,
        model: _taskModels[taskId],
      );
      _startSessionWatch(taskId: taskId, sessionPath: sessionPath);
    }
    final res = await PiSessionIndex.getSessionMessages(
      sessionPath: sessionPath,
      limit: limit,
      beforeIndex: beforeIndex,
    );

    if (res != null) {
      final response = MobilePiMessage(
        messageId: message.messageId,
        from: 'node:$nodeId',
        to: 'client',
        type: MessageType.response,
        payload: {
          ProtocolPayloadKeys.responseTo: message.messageId,
          'sessionPath': sessionPath,
          'messages': res['messages'],
          'totalCount': res['totalCount'],
          'nextBeforeIndex': res['nextBeforeIndex'],
        },
      );
      channel.sink.add(jsonEncode(response.toJson()));
    } else {
      _logger.warning(
        'event=messages.list_failed ${logField('sessionPath', sessionPath)}',
      );
    }
  }

  Future<void> _handleBrowseDirectoryRequest(
    String clientId,
    WebSocketChannel channel,
    MobilePiMessage message,
  ) async {
    final payload = message.payload;
    final requested = payload[ProtocolPayloadKeys.path]?.toString().trim();
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '/';
    final targetPath = (requested == null || requested.isEmpty)
        ? home
        : requested;
    _logger.info(
      'event=directory.browse ${logFields({'requestedPath': requested, 'targetPath': targetPath, 'isHome': targetPath == home})}',
    );
    final responsePayload = <String, dynamic>{
      ProtocolPayloadKeys.path: targetPath,
      ProtocolPayloadKeys.isHome: targetPath == home,
    };

    try {
      final dir = Directory(targetPath);
      if (!dir.existsSync()) {
        responsePayload[ProtocolPayloadKeys.entries] =
            const <Map<String, String>>[];
        responsePayload[ProtocolPayloadKeys.error] = '目录不存在';
      } else {
        final entries = <Map<String, String>>[];
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! Directory) continue;
          final base = entity.path.split(Platform.pathSeparator).last;
          if (base.startsWith('.')) continue; // skip hidden
          entries.add({'name': base, 'path': entity.path});
        }
        entries.sort(
          (a, b) =>
              a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()),
        );
        responsePayload[ProtocolPayloadKeys.entries] = entries;
      }
    } catch (e) {
      _logger.warning(
        'event=directory.browse_failed ${logField('targetPath', targetPath)}',
        e,
      );
      responsePayload[ProtocolPayloadKeys.entries] =
          const <Map<String, String>>[];
      responsePayload[ProtocolPayloadKeys.error] = '$e';
    }

    final response = MobilePiMessage(
      messageId: message.messageId,
      from: 'node:$nodeId',
      to: 'client',
      type: MessageType.response,
      payload: {
        ProtocolPayloadKeys.responseTo: message.messageId,
        ...responsePayload,
      },
    );
    channel.sink.add(jsonEncode(response.toJson()));
  }

  Future<void> _handleCreateDirectoryRequest(
    String clientId,
    WebSocketChannel channel,
    MobilePiMessage message,
  ) async {
    final payload = message.payload;
    final parent =
        payload[ProtocolPayloadKeys.parentPath]?.toString().trim() ?? '';
    final name = payload[ProtocolPayloadKeys.name]?.toString().trim() ?? '';
    final responsePayload = <String, dynamic>{
      ProtocolPayloadKeys.parentPath: parent,
      ProtocolPayloadKeys.name: name,
    };

    if (parent.isEmpty || name.isEmpty) {
      responsePayload[ProtocolPayloadKeys.error] = '缺少 parentPath 或 name';
      _logger.warning(
        'event=directory.create_rejected reason=missing_input ${logFields({'parentPath': parent, 'nameLength': name.length})}',
      );
    } else if (name.contains(Platform.pathSeparator) ||
        name.contains('/') ||
        name == '.' ||
        name == '..') {
      responsePayload[ProtocolPayloadKeys.error] = '非法目录名';
      _logger.warning(
        'event=directory.create_rejected reason=invalid_name ${logFields({'parentPath': parent, 'nameLength': name.length})}',
      );
    } else {
      final newPath = '$parent${Platform.pathSeparator}$name';
      try {
        final dir = Directory(newPath);
        if (dir.existsSync()) {
          responsePayload[ProtocolPayloadKeys.error] = '同名目录已存在';
          _logger.warning(
            'event=directory.create_rejected reason=already_exists ${logField('path', newPath)}',
          );
        } else {
          await dir.create(recursive: false);
          _logger.info('event=directory.created ${logField('path', newPath)}');
        }
        responsePayload[ProtocolPayloadKeys.path] = newPath;
      } catch (e) {
        _logger.warning(
          'event=directory.create_failed ${logField('path', newPath)}',
          e,
        );
        responsePayload[ProtocolPayloadKeys.error] = '$e';
        responsePayload[ProtocolPayloadKeys.path] = newPath;
      }
    }

    final response = MobilePiMessage(
      messageId: message.messageId,
      from: 'node:$nodeId',
      to: 'client',
      type: MessageType.response,
      payload: {
        ProtocolPayloadKeys.responseTo: message.messageId,
        ...responsePayload,
      },
    );
    channel.sink.add(jsonEncode(response.toJson()));
  }

  void _handlePanic(
    String clientId,
    WebSocketChannel channel,
    MobilePiMessage message,
  ) {
    final payload = message.payload;
    final taskId = payload['taskId'] as String?;
    final instanceId = _resolveInstanceId(payload, taskId);
    final activeTaskId = taskId ?? _activeTaskIdsByInstance[instanceId];
    final runner = _activeRunners[instanceId];
    if (runner == null) {
      _logger.info(
        'event=task.panic_noop ${logFields({'taskId': shortId(activeTaskId), 'instanceId': instanceId})}',
      );
      return;
    }

    _logger.warning(
      'event=task.panic ${logFields({'taskId': shortId(activeTaskId), 'instanceId': instanceId})}',
    );
    _runnerSubs.remove(instanceId)?.cancel();
    unawaited(runner.abort());
    _activeRunners.remove(instanceId);
    _activeTaskIdsByInstance.remove(instanceId);

    _sendTaskUpdate(
      channel,
      activeTaskId ?? '',
      'idle',
      streamingText: '用户强制终止',
    );
  }

  void _subscribeToRunner(
    AgentRunner runner,
    String taskId,
    String instanceId,
    WebSocketChannel channel,
  ) {
    _runnerSubs[instanceId] = runner.eventStream.listen(
      (event) {
        String? status;
        String? streamingText;
        String? streamingDelta;
        int? progress;
        Map<String, dynamic>? toolCall;
        Map<String, dynamic>? toolResult;
        String? thinking;
        String? statusLabel;

        switch (event.state) {
          case AgentRunState.starting:
            status = 'running';
            break;
          case AgentRunState.running:
            status = 'running';
            break;
          case AgentRunState.completed:
            status = 'completed';
            break;
          case AgentRunState.aborted:
            status = 'idle';
            break;
          case AgentRunState.error:
            status = 'error';
            break;
        }

        // Pure text delta — no structural markers injected.
        if (event.streamingText != null) {
          streamingDelta = event.streamingText;
        }

        // Structured tool-call event.
        if (event.toolName != null && event.toolName!.isNotEmpty) {
          toolCall = {
            'name': event.toolName,
            if (event.toolCallId != null) 'id': event.toolCallId,
          };
        }

        // Structured tool-result event.
        if (event.toolResult != null && event.toolResult!.isNotEmpty) {
          toolResult = {
            'name': event.toolName ?? '',
            'isError': event.toolResultIsError == true,
            'text': event.toolResult,
            if (event.toolCallId != null) 'id': event.toolCallId,
          };
        }

        // Thinking boundary.
        if (event.thinkingBoundary != null) {
          thinking = event.thinkingBoundary == ThinkingBoundary.start
              ? 'start'
              : 'end';
        }

        // Status label (compaction, retry, etc.).
        if (event.statusLabel != null) {
          statusLabel = event.statusLabel;
        }

        if (event.progress != null) {
          progress = (event.progress! * 100).round();
        }

        _sendTaskUpdate(
          channel,
          taskId,
          status,
          streamingText: streamingText,
          streamingDelta: streamingDelta,
          progressPercent: progress,
          linesAdded: event.linesAdded,
          linesRemoved: event.linesRemoved,
          toolCall: toolCall,
          toolResult: toolResult,
          thinking: thinking,
          statusLabel: statusLabel,
        );
      },
      onDone: () {
        _logger.info(
          'event=runner.done ${logFields({'taskId': shortId(taskId), 'instanceId': instanceId})}',
        );
        _activeRunners.remove(instanceId);
        _activeTaskIdsByInstance.remove(instanceId);
      },
      onError: (e) {
        _logger.warning(
          'event=runner.stream_error ${logFields({'taskId': shortId(taskId), 'instanceId': instanceId})}',
          e,
        );
        _activeRunners.remove(instanceId);
        _activeTaskIdsByInstance.remove(instanceId);
      },
    );
  }

  void _sendTaskUpdate(
    WebSocketChannel channel,
    String taskId,
    String status, {
    String? streamingText,
    String? streamingDelta,
    int? progressPercent,
    int? linesAdded,
    int? linesRemoved,
    Map<String, dynamic>? toolCall,
    Map<String, dynamic>? toolResult,
    String? thinking,
    String? statusLabel,
  }) {
    final payload = _buildTaskUpdatePayload(
      taskId,
      status,
      streamingText: streamingText,
      streamingDelta: streamingDelta,
      progressPercent: progressPercent,
      linesAdded: linesAdded,
      linesRemoved: linesRemoved,
      toolCall: toolCall,
      toolResult: toolResult,
      thinking: thinking,
      statusLabel: statusLabel,
    );
    if (taskId.isNotEmpty) {
      _db!.updateTaskStatus(taskId, status);
    }
    final eventType = _taskEventType(
      status,
      streamingText: streamingText,
      streamingDelta: streamingDelta,
      progressPercent: progressPercent,
      toolCall: toolCall,
      toolResult: toolResult,
      thinking: thinking,
      statusLabel: statusLabel,
    );
    final event = taskId.isEmpty
        ? null
        : _db!.appendEvent(
            streamId: _taskStreamId(taskId),
            type: eventType,
            payload: payload,
          );
    if (event != null) {
      _sendJson(channel, _buildTaskEventJson(event));
    }
  }

  void _sendTaskEvent(
    WebSocketChannel channel,
    String taskId,
    String eventType,
    Map<String, dynamic> payload,
  ) {
    final event = _db!.appendEvent(
      streamId: _taskStreamId(taskId),
      type: eventType,
      payload: payload,
    );
    _sendJson(channel, _buildTaskEventJson(event));
  }

  Map<String, dynamic> _buildTaskUpdatePayload(
    String taskId,
    String status, {
    String? streamingText,
    String? streamingDelta,
    int? progressPercent,
    int? linesAdded,
    int? linesRemoved,
    Map<String, dynamic>? toolCall,
    Map<String, dynamic>? toolResult,
    String? thinking,
    String? statusLabel,
  }) {
    final payload = <String, dynamic>{'taskId': taskId, 'status': status};
    final instanceId = _taskInstanceIds[taskId] ?? _defaultPiInstanceId;
    payload[ProtocolPayloadKeys.piInstanceId] = instanceId;
    final model = _taskModels[taskId];
    if (model != null && model.isNotEmpty) {
      payload[ProtocolPayloadKeys.model] = model;
    }
    if (streamingText != null) payload['streamingText'] = streamingText;
    if (streamingDelta != null) payload['streamingDelta'] = streamingDelta;
    if (progressPercent != null) payload['progressPercent'] = progressPercent;
    if (linesAdded != null) payload['linesAdded'] = linesAdded;
    if (linesRemoved != null) payload['linesRemoved'] = linesRemoved;
    if (toolCall != null) payload[ProtocolPayloadKeys.toolCall] = toolCall;
    if (toolResult != null) payload[ProtocolPayloadKeys.toolResult] = toolResult;
    if (thinking != null) payload[ProtocolPayloadKeys.thinking] = thinking;
    if (statusLabel != null) payload[ProtocolPayloadKeys.statusLabel] = statusLabel;
    return payload;
  }

  Map<String, dynamic> _buildTaskEventJson(NodeEventRecord event) {
    final message = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: 'node:$nodeId',
      to: 'client',
      type: MessageType.event,
      payload: event.toProtocolPayload(),
    );
    return message.toJson();
  }

  String _taskEventType(
    String status, {
    String? streamingText,
    String? streamingDelta,
    int? progressPercent,
    Map<String, dynamic>? toolCall,
    Map<String, dynamic>? toolResult,
    String? thinking,
    String? statusLabel,
  }) {
    if (status == 'completed') return 'task.completed';
    if (status == 'idle') return 'task.aborted';
    if (status == 'error') return 'task.error';
    if (streamingDelta != null) return 'task.output.delta';
    if (streamingText != null) return 'task.output.snapshot';
    if (progressPercent != null) return 'task.progress';
    if (toolCall != null) return 'task.output.delta';
    if (toolResult != null) return 'task.output.delta';
    if (thinking != null) return 'task.output.delta';
    if (statusLabel != null) return 'task.output.delta';
    return 'task.status';
  }

  void _sendJson(WebSocketChannel channel, Map<String, dynamic> messageJson) {
    try {
      _logger.fine('event=ws.send ${summarizeJsonMessage(messageJson)}');
      channel.sink.add(jsonEncode(messageJson));
    } catch (e) {
      _logger.warning(
        'event=ws.send_failed ${summarizeJsonMessage(messageJson)}',
        e,
      );
    }
  }

  String _taskStreamId(String taskId) => 'task:$taskId';

  Map<String, int> _parseCursorMap(Object? raw) {
    if (raw is! Map) return const <String, int>{};
    final result = <String, int>{};
    for (final entry in raw.entries) {
      final key = entry.key?.toString();
      final value = entry.value;
      if (key == null || key.isEmpty) continue;
      if (value is int) {
        result[key] = value;
      } else if (value is num) {
        result[key] = value.toInt();
      } else {
        final parsed = int.tryParse(value?.toString() ?? '');
        if (parsed != null) result[key] = parsed;
      }
    }
    return result;
  }

  String _resolveInstanceId(Map<String, dynamic> payload, String? taskId) {
    final explicit = payload[ProtocolPayloadKeys.piInstanceId]?.toString();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (taskId != null) {
      final byTask = _taskInstanceIds[taskId];
      if (byTask != null && byTask.isNotEmpty) return byTask;
      // 恢复已有会话时，taskId 尚未绑定 instance，但有 sessionPath，
      // 直接用 taskId 作为 instanceId 避免占用 default。
      final hasSessionPath = payload[ProtocolPayloadKeys.sessionPath] != null;
      if (hasSessionPath) return taskId;
    }
    return _defaultPiInstanceId;
  }

  List<PiInstanceInfo> _piInstances() {
    final ids = <String>{_defaultPiInstanceId, ..._activeRunners.keys};
    return ids.map((id) {
      final activeTaskId = _activeTaskIdsByInstance[id];
      return PiInstanceInfo(
        id: id,
        name: id == _defaultPiInstanceId ? 'Default Pi' : 'Pi $id',
        isDefault: id == _defaultPiInstanceId,
        isRunning: _activeRunners[id]?.isRunning == true,
        activeTaskId: activeTaskId,
        model: activeTaskId == null ? null : _taskModels[activeTaskId],
      );
    }).toList();
  }

  PiCapabilities _getPiCapabilities() {
    _refreshPiCapabilitiesIfStale();
    return _piCapabilities;
  }

  void _refreshPiCapabilitiesIfStale() {
    final loadedAt = _piCapabilitiesLoadedAt;
    if (loadedAt != null &&
        DateTime.now().difference(loadedAt) < _piCapabilityCacheTtl) {
      return;
    }
    if (_piCapabilitiesRefresh != null) return;
    _piCapabilitiesRefresh = _loadPiCapabilities()
        .then((capabilities) {
          _piCapabilities = capabilities;
        })
        .whenComplete(() {
          _piCapabilitiesRefresh = null;
        });
    unawaited(_piCapabilitiesRefresh!);
  }

  Future<PiCapabilities> _loadPiCapabilities() async {
    var sessions = const <PiSessionInfo>[];
    final client = PiRpcClient();
    try {
      await client.start();
      final state = await client.getState();
      final activeSessionPath = state['sessionPath']?.toString();
      sessions = await _loadPiSessions(activeSessionPath: activeSessionPath);
      final currentModel = _modelPathFromRpc(state['model']);
      final models =
          (await client.getAvailableModels())
              .map((model) {
                return PiModelInfo.fromRpcModel(
                  model,
                  currentModelPath: currentModel,
                );
              })
              .where((model) => model.id.isNotEmpty)
              .toList()
            ..sort((a, b) => a.id.compareTo(b.id));
      final commands =
          (await client.getCommands())
              .map(PiSlashCommandInfo.fromRpcCommand)
              .where((command) => command.name.isNotEmpty)
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      var messages = <Map<String, dynamic>>[];
      try {
        messages = await client.getMessages();
      } catch (e) {
        _logger.warning('event=pi.capabilities.messages_failed', e);
      }

      _piCapabilitiesLoadedAt = DateTime.now();
      final capabilitiesFields = <String, Object?>{
        'models': models.length,
        'slashCommands': commands.length,
        'messages': messages.length,
        'sessions': sessions.length,
      };
      if (currentModel != null) {
        capabilitiesFields['defaultModel'] = currentModel;
      }
      _logger.info(
        'event=pi.capabilities.loaded ${logFields(capabilitiesFields)}',
      );
      return PiCapabilities(
        defaultModel: currentModel,
        models: models,
        slashCommands: commands,
        state: state,
        messages: messages,
        sessions: sessions,
      );
    } catch (e) {
      _logger.warning('event=pi.capabilities.failed', e);
      _piCapabilitiesLoadedAt = DateTime.now();
      return PiCapabilities(
        defaultModel: null,
        models: const <PiModelInfo>[],
        slashCommands: const <PiSlashCommandInfo>[],
        sessions: sessions,
      );
    } finally {
      await client.stop();
    }
  }

  Future<List<PiSessionInfo>> _loadPiSessions({
    String? activeSessionPath,
  }) async {
    try {
      return await PiSessionIndex(
        cwd: Directory.current.path,
      ).listAll(limit: 20, activeSessionPath: activeSessionPath);
    } catch (e) {
      _logger.warning('event=pi.sessions.failed', e);
      return const <PiSessionInfo>[];
    }
  }

  static String normalizeHubUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw FormatException('Hub URL 不能为空');
    }

    final schemeMatch = RegExp(
      r'^([a-zA-Z]+)://',
      caseSensitive: false,
    ).firstMatch(trimmed);
    late final String scheme;
    late final String remainder;
    if (schemeMatch != null) {
      final parsedScheme = schemeMatch.group(1)!.toLowerCase();
      if (parsedScheme == 'https' || parsedScheme == 'wss') {
        scheme = 'wss';
      } else if (parsedScheme == 'http' || parsedScheme == 'ws') {
        scheme = 'ws';
      } else {
        throw FormatException('Hub URL scheme 必须是 ws/wss/http/https');
      }
      remainder = trimmed.substring(schemeMatch.end);
    } else {
      scheme = 'ws';
      remainder = trimmed;
    }

    final uri = Uri.parse('$scheme://$remainder');
    if (uri.host.isEmpty) {
      throw FormatException('无效的 Hub URL: $url');
    }

    final isIpv6Host = uri.host.contains(':');
    final normalizedHost = isIpv6Host ? '[${uri.host}]' : uri.host;

    var result = '$scheme://$normalizedHost';
    if (uri.hasPort) {
      result += ':${uri.port}';
    }
    if (uri.path.isNotEmpty && uri.path != '/') {
      result += uri.path;
    } else {
      result += '/ws';
    }
    return result;
  }

  static String? _modelPathFromRpc(Object? model) {
    if (model is! Map) return null;
    final provider =
        model['provider']?.toString() ??
        model['providerId']?.toString() ??
        model['providerName']?.toString();
    final id =
        model['id']?.toString() ??
        model['model']?.toString() ??
        model['modelId']?.toString();
    if (id == null || id.isEmpty) return null;
    if (id.contains('/')) return id;
    if (provider == null || provider.isEmpty) return id;
    return '$provider/$id';
  }
}
