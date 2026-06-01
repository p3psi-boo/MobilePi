import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/node_state.dart';
import '../services/websocket_service.dart';

const String _kHubUrlPrefKey = 'mobilepi.hubUrl';
const String _kTenantKeyPrefKey = 'mobilepi.tenantKey';
const String _kCursorPrefKey = 'mobilepi.cursors';
const int _kMaxStreamingTextLength = 24000;

/// 任务运行时状态
/// A structured tool call recorded during streaming.
class StreamingToolEvent {
  final String name;
  final String? id;
  final bool isResult;
  final bool isError;
  final String? resultText;

  const StreamingToolEvent.call({required this.name, this.id})
    : isResult = false,
      isError = false,
      resultText = null;

  const StreamingToolEvent.result({
    required this.name,
    this.id,
    required this.isError,
    required this.resultText,
  }) : isResult = true;
}

class TaskState {
  final String id;
  final String nodeId;
  final String projectId;
  final String projectPath;
  final String? sessionId;
  final String? sessionPath;
  final String agentType;
  final String? piInstanceId;
  final String? model;
  final String title;
  final String status; // idle|running|waitingDecision|error|completed|history
  final String? streamingText;

  /// Structured streaming text segments derived from protocol fields.
  /// Rendering must use this instead of parsing tags out of [streamingText].
  final List<MessagePart> streamingParts;

  final List<PiSessionMessageInfo> messages;
  final int? progressPercent;
  final int? linesAdded;
  final int? linesRemoved;
  final int? nextBeforeIndex;
  final int? totalCount;
  final DateTime createdAt;

  /// Structured tool events accumulated during streaming.
  /// Filled by `toolCall`/`toolResult` protocol payloads — never from text.
  final List<StreamingToolEvent> toolEvents;

  /// Whether the model is currently thinking (structured boundary).
  /// `true` after `thinking: "start"`, `false` after `thinking: "end"`.
  final bool isThinking;

  /// Status labels (compaction, retry, etc.) shown transiently.
  final String? statusLabel;

  TaskState({
    required this.id,
    required this.nodeId,
    required this.projectId,
    required this.projectPath,
    this.sessionId,
    this.sessionPath,
    this.agentType = 'pi',
    this.piInstanceId,
    this.model,
    required this.title,
    this.status = 'idle',
    this.streamingText,
    this.streamingParts = const [],
    this.messages = const [],
    this.progressPercent,
    this.linesAdded,
    this.linesRemoved,
    this.nextBeforeIndex,
    this.totalCount,
    this.toolEvents = const [],
    this.isThinking = false,
    this.statusLabel,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  TaskState copyWith({
    String? status,
    String? projectId,
    String? projectPath,
    String? sessionId,
    String? sessionPath,
    String? piInstanceId,
    String? model,
    String? streamingText,
    List<MessagePart>? streamingParts,
    List<PiSessionMessageInfo>? messages,
    int? progressPercent,
    int? linesAdded,
    int? linesRemoved,
    int? nextBeforeIndex,
    int? totalCount,
    List<StreamingToolEvent>? toolEvents,
    bool? isThinking,
    String? statusLabel,
  }) {
    return TaskState(
      id: id,
      nodeId: nodeId,
      projectId: projectId ?? this.projectId,
      projectPath: projectPath ?? this.projectPath,
      sessionId: sessionId ?? this.sessionId,
      sessionPath: sessionPath ?? this.sessionPath,
      agentType: agentType,
      piInstanceId: piInstanceId ?? this.piInstanceId,
      model: model ?? this.model,
      title: title,
      status: status ?? this.status,
      streamingText: streamingText ?? this.streamingText,
      streamingParts: streamingParts ?? this.streamingParts,
      messages: messages ?? this.messages,
      progressPercent: progressPercent ?? this.progressPercent,
      linesAdded: linesAdded ?? this.linesAdded,
      linesRemoved: linesRemoved ?? this.linesRemoved,
      nextBeforeIndex: nextBeforeIndex ?? this.nextBeforeIndex,
      totalCount: totalCount ?? this.totalCount,
      toolEvents: toolEvents ?? this.toolEvents,
      isThinking: isThinking ?? this.isThinking,
      statusLabel: statusLabel ?? this.statusLabel,
      createdAt: createdAt,
    );
  }

  String get displayTitle {
    final userPreview = _firstMessagePreview(
      messages.where((message) => message.role == 'user'),
    );
    if (userPreview.isNotEmpty) return _singleLineTitle(userPreview);

    final messagePreview = _firstMessagePreview(messages);
    if (messagePreview.isNotEmpty) return _singleLineTitle(messagePreview);

    return _singleLineTitle(title);
  }
}

String _firstMessagePreview(Iterable<PiSessionMessageInfo> messages) {
  for (final message in messages) {
    final preview = message.structuredPreviewText;
    if (preview.isNotEmpty) return preview;
  }
  return '';
}

String _singleLineTitle(String text) {
  final singleLine = text.replaceAll('\n', ' ').trim();
  return singleLine.length > 80
      ? '${singleLine.substring(0, 80)}...'
      : singleLine;
}

/// Result of a remote directory listing.
class DirectoryListing {
  final String path;
  final bool isHome;
  final List<DirectoryEntry> entries;
  final String? error;

  const DirectoryListing({
    required this.path,
    required this.isHome,
    required this.entries,
    this.error,
  });
}

class DirectoryEntry {
  final String name;
  final String path;
  const DirectoryEntry({required this.name, required this.path});
}

class ProjectState {
  final String id;
  final String nodeId;
  final String path;
  final String name;
  final int sessionCount;
  final DateTime? lastSeenAt;

  const ProjectState({
    required this.id,
    required this.nodeId,
    required this.path,
    required this.name,
    this.sessionCount = 0,
    this.lastSeenAt,
  });
}

class ProjectSessionState {
  final String id;
  final String nodeId;
  final String projectId;
  final String title;
  final String status;
  final DateTime? updatedAt;
  final TaskState? task;

  const ProjectSessionState({
    required this.id,
    required this.nodeId,
    required this.projectId,
    required this.title,
    required this.status,
    this.updatedAt,
    this.task,
  });
}

/// 节点状态 Provider
///
/// 管理 WebSocket 连接、Node 列表、任务状态。
class NodeProvider extends ChangeNotifier {
  final WebSocketService _ws;
  final Map<String, NodeState> _nodes = {};
  final Map<String, TaskState> _tasks = {};
  final Map<String, Map<String, int>> _cursorsByNode = {};
  final Map<String, Completer<DirectoryListing>> _pendingBrowse = {};
  final Map<String, Completer<String>> _pendingCreate = {};
  late final StreamSubscription<MobilePiMessage> _messageSub;
  late final StreamSubscription<bool> _connectionSub;
  Timer? _streamingNotifyTimer;
  Timer? _cursorSaveTimer;
  late String _hubUrl;
  late String _tenantKey;
  bool _connecting = false;
  bool _settingsLoaded = false;

  NodeProvider({WebSocketService? webSocketService})
    : _ws = webSocketService ?? WebSocketService() {
    _hubUrl = _ws.hubUrl;
    _tenantKey = _ws.tenantKey;
    _messageSub = _ws.messageStream.listen(_onMessage);
    _connectionSub = _ws.connectionStream.listen(_onConnectionChanged);
  }

  List<NodeState> get nodes => List.unmodifiable(_nodes.values);

  /// 按状态分类的任务
  List<TaskState> get runningTasks =>
      _tasks.values.where((t) => t.status == 'running').toList();
  List<TaskState> get waitingTasks =>
      _tasks.values.where((t) => t.status == 'waitingDecision').toList();
  List<TaskState> get idleTasks => _tasks.values
      .where(
        (t) =>
            t.status == 'idle' ||
            t.status == 'completed' ||
            t.status == 'error',
      )
      .toList();
  List<TaskState> get recentTasks {
    final tasks = _tasks.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(tasks);
  }

  bool get isConnecting => _connecting;
  bool get isConnected => _ws.isConnected;
  bool get hasOnlineNodes => _nodes.values.any((n) => n.online);
  String get hubUrl => _hubUrl;
  String get tenantKey => _tenantKey;
  bool get hasTenantKey => _tenantKey.trim().isNotEmpty;

  Future<void> loadSettings() async {
    if (_settingsLoaded) return;
    _settingsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kHubUrlPrefKey)?.trim();
      if (saved != null && saved.isNotEmpty) {
        try {
          _ws.updateHubUrl(saved);
        } on FormatException {
          // 忽略坏的持久化值，沿用默认 URL
        }
      }
      final savedTenantKey = prefs.getString(_kTenantKeyPrefKey)?.trim();
      if (savedTenantKey != null && savedTenantKey.isNotEmpty) {
        _ws.updateTenantKey(savedTenantKey);
      }
      final rawCursors = prefs.getString(_kCursorPrefKey);
      if (rawCursors != null && rawCursors.isNotEmpty) {
        _restoreCursors(rawCursors);
      }
    } catch (_) {
      // SharedPreferences 在某些平台 / 测试里可能不可用
    }
    _hubUrl = _ws.hubUrl;
    _tenantKey = _ws.tenantKey;
    notifyListeners();
  }

  /// 更新 Hub URL：归一化 + 持久化 + 立刻重连。
  /// 失败时抛 [FormatException]。
  Future<void> setHubUrl(String url) async {
    final normalized = _ws.updateHubUrl(url);
    _hubUrl = normalized;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHubUrlPrefKey, normalized);
    } catch (_) {
      // 持久化失败不阻塞，本次运行仍生效
    }
    notifyListeners();
    connect();
  }

  /// 更新 Hub URL 和租户 key：归一化 + 持久化 + 立刻重连。
  Future<void> setHubConnection({
    required String url,
    required String tenantKey,
  }) async {
    final normalizedKey = WebSocketService.normalizeTenantKey(tenantKey);
    if (normalizedKey.isEmpty) {
      throw const FormatException('Key 不能为空');
    }
    final normalizedUrl = _ws.updateHubUrl(url);
    _ws.updateTenantKey(normalizedKey);
    _hubUrl = normalizedUrl;
    _tenantKey = normalizedKey;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHubUrlPrefKey, normalizedUrl);
      await prefs.setString(_kTenantKeyPrefKey, normalizedKey);
    } catch (_) {
      // 持久化失败不阻塞，本次运行仍生效
    }
    notifyListeners();
    connect();
  }

  void connect() {
    if (!hasTenantKey) {
      _connecting = false;
      notifyListeners();
      return;
    }
    if (_ws.isConnected || _connecting) return;
    _connecting = true;
    notifyListeners();
    _ws.connect();
  }

  void disconnect() {
    _ws.disconnect();
    _markAllOffline();
  }

  void refresh() {
    if (_ws.isConnected) {
      _sendHelloAndResume();
    } else {
      connect();
    }
  }

  /// app 从后台切回前台时调用：强制重连 + 差量同步，确保进度连续性。
  /// 即便 `_ws.isConnected` 仍为 true，移动端冻结后的 socket 也可能是僵尸，
  /// 故走 forceReconnect 重建连接（重连成功后 _onConnectionChanged 会 resume）。
  void onAppResumed() {
    if (!hasTenantKey) return;
    _ws.forceReconnect();
  }

  void _onConnectionChanged(bool connected) {
    _connecting = false;
    if (connected) {
      _sendHelloAndResume();
    } else {
      _markAllOffline();
    }
    notifyListeners();
  }

  void _sendHelloAndResume() {
    _ws.sendHello(lastCursors: _cursorsByNode);
    for (final node in _nodes.values.where((node) => node.online)) {
      _ws.sendResume(node.nodeId, _cursorsByNode[node.nodeId] ?? const {});
    }
  }

  void _onMessage(MobilePiMessage message) {
    switch (message.type) {
      case MessageType.response:
        _handleProtocolResponse(message);
        break;
      case MessageType.event:
        _handleProtocolEvent(message);
        break;
      default:
        break;
    }
  }

  void _handleBrowseDirectoryResponse(
    Map<String, dynamic> payload, {
    required String responseTo,
  }) {
    final completer = _pendingBrowse.remove(responseTo);
    if (completer == null) return;
    final entries =
        (payload[ProtocolPayloadKeys.entries] as List<dynamic>?)
            ?.whereType<Map>()
            .map(
              (e) => DirectoryEntry(
                name: e['name']?.toString() ?? '',
                path: e['path']?.toString() ?? '',
              ),
            )
            .where((e) => e.name.isNotEmpty && e.path.isNotEmpty)
            .toList() ??
        const <DirectoryEntry>[];
    completer.complete(
      DirectoryListing(
        path: payload[ProtocolPayloadKeys.path]?.toString() ?? '',
        isHome: payload[ProtocolPayloadKeys.isHome] as bool? ?? false,
        entries: entries,
        error: payload[ProtocolPayloadKeys.error]?.toString(),
      ),
    );
  }

  void _handleCreateDirectoryResponse(
    Map<String, dynamic> payload, {
    required String responseTo,
  }) {
    final completer = _pendingCreate.remove(responseTo);
    if (completer == null) return;
    final error = payload[ProtocolPayloadKeys.error]?.toString();
    if (error != null && error.isNotEmpty) {
      completer.completeError(Exception(error));
      return;
    }
    completer.complete(payload[ProtocolPayloadKeys.path]?.toString() ?? '');
  }

  void _applyNodeSummary(Map<String, dynamic> payload, {required String from}) {
    final nodeId =
        payload[ProtocolPayloadKeys.nodeId] as String? ??
        _normalizeNodeId(from);
    final hostname = payload[ProtocolPayloadKeys.hostname] as String? ?? nodeId;
    final platform = payload[ProtocolPayloadKeys.platform] as String? ?? '';
    final agents =
        (payload[ProtocolPayloadKeys.agents] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];
    final piModels =
        (payload[ProtocolPayloadKeys.piModels] as List<dynamic>?)
            ?.whereType<Map>()
            .map((e) => PiModelInfo.fromJson(Map<String, dynamic>.from(e)))
            .where((m) => m.id.isNotEmpty)
            .toList() ??
        <PiModelInfo>[];
    final piSlashCommands =
        (payload[ProtocolPayloadKeys.piSlashCommands] as List<dynamic>?)
            ?.whereType<Map>()
            .map(
              (e) => PiSlashCommandInfo.fromJson(Map<String, dynamic>.from(e)),
            )
            .where((c) => c.name.isNotEmpty)
            .toList() ??
        <PiSlashCommandInfo>[];
    final piInstances =
        (payload[ProtocolPayloadKeys.piInstances] as List<dynamic>?)
            ?.whereType<Map>()
            .map((e) => PiInstanceInfo.fromJson(Map<String, dynamic>.from(e)))
            .where((instance) => instance.id.isNotEmpty)
            .toList() ??
        <PiInstanceInfo>[];
    final piState = payload[ProtocolPayloadKeys.piState] is Map
        ? Map<String, dynamic>.from(payload[ProtocolPayloadKeys.piState] as Map)
        : null;
    final piMessages =
        (payload[ProtocolPayloadKeys.piMessages] as List<dynamic>?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        <Map<String, dynamic>>[];
    final piSessions =
        (payload[ProtocolPayloadKeys.piSessions] as List<dynamic>?)
            ?.whereType<Map>()
            .map((e) => PiSessionInfo.fromJson(Map<String, dynamic>.from(e)))
            .where((session) => session.id.isNotEmpty)
            .toList() ??
        <PiSessionInfo>[];

    _nodes[nodeId] = NodeState(
      nodeId: nodeId,
      hostname: hostname,
      platform: platform,
      agents: agents,
      piModels: piModels,
      piDefaultModel: payload[ProtocolPayloadKeys.piDefaultModel]?.toString(),
      piSlashCommands: piSlashCommands,
      piInstances: piInstances,
      piState: piState,
      piMessages: piMessages,
      piSessions: piSessions,
      online: payload[ProtocolPayloadKeys.online] as bool? ?? true,
      lastSeenAt: DateTime.now(),
    );
    _syncPiSessions(nodeId, piSessions);

    notifyListeners();
  }

  void _handleProtocolResponse(MobilePiMessage message) {
    final payload = message.payload;
    final responseTo = payload[ProtocolPayloadKeys.responseTo]?.toString();
    if (responseTo != null) {
      if (_pendingBrowse.containsKey(responseTo)) {
        _handleBrowseDirectoryResponse(payload, responseTo: responseTo);
        return;
      }
      if (_pendingCreate.containsKey(responseTo)) {
        _handleCreateDirectoryResponse(payload, responseTo: responseTo);
        return;
      }
    }
    if (payload['sessionPath'] != null && payload['messages'] != null) {
      _handleSessionMessagesResponse(payload);
      return;
    }

    final nodeSummaries =
        (payload[ProtocolPayloadKeys.nodeSummaries] as List<dynamic>?)
            ?.whereType<Map>()
            .map((summary) => Map<String, dynamic>.from(summary))
            .toList() ??
        const <Map<String, dynamic>>[];
    Logger('NodeProvider').info(
      'event=node_summaries.received ${logFields({'count': nodeSummaries.length, 'from': message.from, 'responseTo': responseTo})}',
    );
    for (final summary in nodeSummaries) {
      final nodeId =
          summary[ProtocolPayloadKeys.nodeId]?.toString() ??
          _normalizeNodeId(message.from);
      _applyNodeSummary(summary, from: nodeId);
      _ws.sendResume(nodeId, _cursorsByNode[nodeId] ?? const {});
    }

    final nodeSummary = payload[ProtocolPayloadKeys.nodeSummary];
    if (nodeSummary is Map) {
      final summary = Map<String, dynamic>.from(nodeSummary);
      final nodeId =
          summary[ProtocolPayloadKeys.nodeId]?.toString() ??
          _normalizeNodeId(message.from);
      Logger('NodeProvider').info(
        'event=node_summary.received ${logFields({'nodeId': nodeId, 'from': message.from})}',
      );
      _applyNodeSummary(summary, from: nodeId);
    }

    final events =
        (payload[ProtocolPayloadKeys.events] as List<dynamic>?)
            ?.whereType<Map>()
            .map((event) => Map<String, dynamic>.from(event))
            .toList() ??
        const <Map<String, dynamic>>[];
    if (events.isNotEmpty) {
      final nodeId = _normalizeNodeId(message.from);
      for (final event in events) {
        _applyProtocolEvent(nodeId, event, notify: false);
      }
      _notifyNow();
    }
  }

  void _handleProtocolEvent(MobilePiMessage message) {
    _applyProtocolEvent(
      _normalizeNodeId(message.from),
      message.payload,
      notify: true,
    );
  }

  void _applyProtocolEvent(
    String nodeId,
    Map<String, dynamic> event, {
    required bool notify,
  }) {
    final streamId = event[ProtocolPayloadKeys.streamId]?.toString();
    final seq = _intValue(event[ProtocolPayloadKeys.seq]);
    final eventType = event[ProtocolPayloadKeys.eventType]?.toString();
    final rawPayload = event[ProtocolPayloadKeys.eventPayload];
    if (streamId == null ||
        streamId.isEmpty ||
        seq == null ||
        eventType == null ||
        rawPayload is! Map) {
      return;
    }

    final nodeCursors = _cursorsByNode.putIfAbsent(
      nodeId,
      () => <String, int>{},
    );
    final currentSeq = nodeCursors[streamId] ?? 0;
    if (seq <= currentSeq) return;

    final taskPayload = Map<String, dynamic>.from(rawPayload);
    taskPayload['taskId'] ??= event['taskId'];
    _normalizeTaskPayloadFromEvent(eventType, taskPayload);
    _applyTaskUpdatePayload(
      nodeId: nodeId,
      payload: taskPayload,
      notify: notify,
    );
    nodeCursors[streamId] = seq;
    _scheduleCursorSave();
  }

  void _normalizeTaskPayloadFromEvent(
    String eventType,
    Map<String, dynamic> payload,
  ) {
    switch (eventType) {
      case 'task.created':
      case 'task.started':
      case 'task.status':
        payload['status'] ??= 'running';
        break;
      case 'task.completed':
        payload['status'] = 'completed';
        break;
      case 'task.aborted':
        payload['status'] = 'idle';
        break;
      case 'task.error':
        payload['status'] = 'error';
        payload['streamingText'] ??= payload['message']?.toString();
        break;
      case 'task.output.delta':
        payload['status'] ??= 'running';
        payload['streamingDelta'] ??= payload['text']?.toString();
        break;
      case 'task.output.snapshot':
        payload['status'] ??= 'running';
        payload['streamingText'] ??= payload['text']?.toString();
        break;
      case 'task.progress':
        payload['status'] ??= 'running';
        payload['progressPercent'] ??= _intValue(payload['percent']);
        break;
    }
  }

  void _applyTaskUpdatePayload({
    required String nodeId,
    required Map<String, dynamic> payload,
    bool notify = true,
  }) {
    final taskId = payload['taskId'] as String? ?? '';
    final status = payload['status'] as String? ?? 'running';
    final streamingText = payload['streamingText'] as String?;
    final streamingDelta = payload['streamingDelta'] as String?;
    final messages = (payload[ProtocolPayloadKeys.piMessages] as List<dynamic>?)
        ?.whereType<Map>()
        .map((e) => PiSessionMessageInfo.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final model = payload[ProtocolPayloadKeys.model]?.toString();
    final piInstanceId = payload[ProtocolPayloadKeys.piInstanceId]?.toString();
    final progressPercent = payload['progressPercent'] as int?;
    final linesAdded = payload['linesAdded'] as int?;
    final linesRemoved = payload['linesRemoved'] as int?;
    final projectPath = payload[ProtocolPayloadKeys.projectPath]?.toString();
    final project = projectPath == null || projectPath.isEmpty
        ? defaultProjectForNode(nodeId)
        : ProjectState(
            id: _projectId(nodeId, projectPath),
            nodeId: nodeId,
            path: projectPath,
            name: _projectName(projectPath),
          );

    // --- Structured fields ---
    final toolCallRaw = payload[ProtocolPayloadKeys.toolCall];
    final toolResultRaw = payload[ProtocolPayloadKeys.toolResult];
    final thinkingRaw = payload[ProtocolPayloadKeys.thinking]?.toString();
    final statusLabel = payload[ProtocolPayloadKeys.statusLabel]?.toString();

    if (taskId.isEmpty) return;

    final existing = _tasks[taskId];

    // Build updated tool events list
    var toolEvents = existing?.toolEvents ?? <StreamingToolEvent>[];
    if (toolCallRaw is Map) {
      toolEvents = [
        ...toolEvents,
        StreamingToolEvent.call(
          name: toolCallRaw['name']?.toString() ?? '',
          id: toolCallRaw['id']?.toString(),
        ),
      ];
    }
    if (toolResultRaw is Map) {
      toolEvents = [
        ...toolEvents,
        StreamingToolEvent.result(
          name: toolResultRaw['name']?.toString() ?? '',
          id: toolResultRaw['id']?.toString(),
          isError: toolResultRaw['isError'] == true,
          resultText: toolResultRaw['text']?.toString(),
        ),
      ];
    }

    // Thinking boundary
    bool? isThinking;
    if (thinkingRaw == 'start') isThinking = true;
    if (thinkingRaw == 'end') isThinking = false;
    if (status != 'running' && thinkingRaw == null) isThinking = false;

    // Pure text delta
    String? nextStreamingText = streamingText;
    if (nextStreamingText == null && streamingDelta != null) {
      nextStreamingText = '${existing?.streamingText ?? ''}$streamingDelta';
    }
    if (nextStreamingText != null &&
        nextStreamingText.length > _kMaxStreamingTextLength) {
      nextStreamingText = nextStreamingText.substring(
        nextStreamingText.length - _kMaxStreamingTextLength,
      );
    }

    final nextStreamingParts = _structuredStreamingParts(
      existing: existing,
      streamingText: streamingText,
      streamingDelta: streamingDelta,
      isThinking: isThinking ?? existing?.isThinking ?? false,
    );

    if (existing != null) {
      _tasks[taskId] = existing.copyWith(
        status: status,
        piInstanceId: piInstanceId,
        model: model,
        streamingText: nextStreamingText,
        streamingParts: nextStreamingParts,
        messages: messages,
        progressPercent: progressPercent,
        linesAdded: linesAdded,
        linesRemoved: linesRemoved,
        toolEvents: toolEvents,
        isThinking: isThinking,
        statusLabel: statusLabel,
      );
    } else {
      _tasks[taskId] = TaskState(
        id: taskId,
        nodeId: nodeId,
        projectId: project.id,
        projectPath: project.path,
        sessionId: _sessionIdForNode(nodeId),
        piInstanceId: piInstanceId,
        model: model,
        title: payload[ProtocolPayloadKeys.title]?.toString() ?? '任务 $taskId',
        status: status,
        streamingText: nextStreamingText,
        streamingParts: nextStreamingParts ?? const [],
        messages: messages ?? const [],
        progressPercent: progressPercent,
        linesAdded: linesAdded,
        linesRemoved: linesRemoved,
        toolEvents: toolEvents,
        isThinking: isThinking ?? false,
        statusLabel: statusLabel,
      );
    }

    if (!notify) return;
    if (existing != null && status == 'running' && nextStreamingText != null) {
      _notifyStreamingSoon();
    } else {
      _notifyNow();
    }
    _pruneOldTasks();
  }

  List<MessagePart>? _structuredStreamingParts({
    required TaskState? existing,
    required String? streamingText,
    required String? streamingDelta,
    required bool isThinking,
  }) {
    if (streamingText == null && streamingDelta == null) return null;

    if (streamingText != null) {
      final part = isThinking
          ? MessagePart.thinking(streamingText)
          : MessagePart.text(streamingText);
      return _trimStreamingParts([part]);
    }

    final delta = streamingDelta;
    if (delta == null || delta.isEmpty) {
      return existing?.streamingParts ?? const [];
    }

    final parts = List<MessagePart>.from(existing?.streamingParts ?? const []);
    if (parts.isEmpty || parts.last.type != _streamingPartType(isThinking)) {
      parts.add(
        isThinking ? MessagePart.thinking(delta) : MessagePart.text(delta),
      );
    } else {
      final last = parts.removeLast();
      final text = '${last.text ?? ''}$delta';
      parts.add(
        isThinking ? MessagePart.thinking(text) : MessagePart.text(text),
      );
    }
    return _trimStreamingParts(parts);
  }

  MessagePartType _streamingPartType(bool isThinking) {
    return isThinking ? MessagePartType.thinking : MessagePartType.text;
  }

  List<MessagePart> _trimStreamingParts(List<MessagePart> parts) {
    var remaining = _kMaxStreamingTextLength;
    final kept = <MessagePart>[];

    for (final part in parts.reversed) {
      final text = part.text ?? '';
      if (text.isEmpty) continue;
      if (text.length <= remaining) {
        kept.add(part);
        remaining -= text.length;
        continue;
      }
      if (remaining > 0) {
        kept.add(
          _copyPartWithText(part, text.substring(text.length - remaining)),
        );
      }
      break;
    }

    return kept.reversed.toList();
  }

  MessagePart _copyPartWithText(MessagePart part, String text) {
    return switch (part.type) {
      MessagePartType.thinking => MessagePart.thinking(text),
      _ => MessagePart.text(text),
    };
  }

  void _handleSessionMessagesResponse(Map<String, dynamic> payload) {
    final sessionPath = payload['sessionPath'] as String? ?? '';
    if (sessionPath.isEmpty) return;

    final rawMessages = payload['messages'] as List<dynamic>? ?? const [];
    final newMessages = rawMessages
        .whereType<Map>()
        .map((e) => PiSessionMessageInfo.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    final totalCount = payload['totalCount'] as int? ?? 0;
    final nextBeforeIndex = payload['nextBeforeIndex'] as int?;

    TaskState? targetTask;
    for (final task in _tasks.values) {
      if (task.sessionPath == sessionPath) {
        targetTask = task;
        break;
      }
    }

    if (targetTask == null) return;

    // Filter duplicates just in case
    final Set<String> existingKeys = targetTask.messages
        .map((m) => '${m.role}:${m.text}')
        .toSet();
    final uniqueNewMessages = newMessages
        .where((m) => !existingKeys.contains('${m.role}:${m.text}'))
        .toList();

    final updatedMessages = [...uniqueNewMessages, ...targetTask.messages];

    _tasks[targetTask.id] = targetTask.copyWith(
      messages: updatedMessages,
      nextBeforeIndex: nextBeforeIndex,
      totalCount: totalCount,
    );

    notifyListeners();
  }

  /// 创建并发送任务指令
  String sendTaskCommand(
    String prompt, {
    String nodeId = '',
    String? projectId,
    String? projectPath,
    String agentType = 'pi',
    String? piInstanceId,
    String? model,
  }) {
    final taskId = const Uuid().v4();

    // 选择目标 Node（取第一个在线 Node）
    String targetNodeId = nodeId;
    if (targetNodeId.isEmpty) {
      final onlineNodes = _nodes.values.where((n) => n.online).toList();
      if (onlineNodes.isEmpty) return taskId;
      targetNodeId = onlineNodes.first.nodeId;
    }
    final project = projectId == null
        ? defaultProjectForNode(targetNodeId)
        : ProjectState(
            id: projectId,
            nodeId: targetNodeId,
            path: projectPath ?? projectId,
            name: _projectName(projectPath ?? projectId),
          );

    // 本地预创建任务
    _tasks[taskId] = TaskState(
      id: taskId,
      nodeId: targetNodeId,
      projectId: project.id,
      projectPath: project.path,
      sessionId: taskId,
      agentType: agentType,
      piInstanceId: piInstanceId,
      model: model,
      title: prompt.length > 80 ? '${prompt.substring(0, 80)}...' : prompt,
      messages: [PiSessionMessageInfo(role: 'user', text: prompt)],
      status: 'running',
    );
    notifyListeners();

    _ws.sendTaskCommand(
      targetNodeId,
      taskId,
      prompt,
      agentType: agentType,
      piInstanceId: piInstanceId,
      model: model,
      projectPath: project.path,
    );

    return taskId;
  }

  void sendPanic(String nodeId, {String? taskId}) {
    _ws.sendPanic(nodeId, taskId: taskId);
  }

  void sendSteer(String taskId, String message, {String? model}) {
    final task = _tasks[taskId];
    if (task == null) return;
    _appendLocalUserMessage(task, message);
    _ws.sendSteerCommand(
      task.nodeId,
      taskId,
      message,
      sessionPath: task.sessionPath,
      model: model,
    );
  }

  void sendFollowUp(String taskId, String message, {String? model}) {
    final task = _tasks[taskId];
    if (task == null) return;
    _appendLocalUserMessage(task, message);
    _ws.sendFollowUpCommand(
      task.nodeId,
      taskId,
      message,
      sessionPath: task.sessionPath,
      model: model,
    );
  }

  void _appendLocalUserMessage(TaskState task, String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;

    _tasks[task.id] = task.copyWith(
      messages: [
        ...task.messages,
        PiSessionMessageInfo(
          role: 'user',
          text: trimmed,
          timestamp: DateTime.now(),
        ),
      ],
    );
    notifyListeners();
  }

  Future<void> requestSessionMessages(
    String nodeId,
    String taskId,
    String sessionPath, {
    int limit = 20,
    int? beforeIndex,
  }) async {
    if (!_ws.isConnected) return;
    _ws.sendSessionMessagesRequest(
      nodeId,
      sessionPath,
      taskId: taskId,
      limit: limit,
      beforeIndex: beforeIndex,
    );
  }

  /// Browse a directory on the remote node.
  ///
  /// If [path] is null/empty the daemon returns its home directory.
  Future<DirectoryListing> browseDirectory(String nodeId, {String? path}) {
    if (!_ws.isConnected) {
      return Future.error(StateError('未连接到 Hub'));
    }
    final messageId = _ws.sendBrowseDirectoryRequest(nodeId, path: path);
    final completer = Completer<DirectoryListing>();
    _pendingBrowse[messageId] = completer;
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pendingBrowse.remove(messageId);
        throw TimeoutException('浏览目录超时');
      },
    );
  }

  /// Create a directory under [parentPath]. Returns the new absolute path.
  Future<String> createDirectory(
    String nodeId, {
    required String parentPath,
    required String name,
  }) {
    if (!_ws.isConnected) {
      return Future.error(StateError('未连接到 Hub'));
    }
    final messageId = _ws.sendCreateDirectoryRequest(
      nodeId,
      parentPath: parentPath,
      name: name,
    );
    final completer = Completer<String>();
    _pendingCreate[messageId] = completer;
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pendingCreate.remove(messageId);
        throw TimeoutException('创建目录超时');
      },
    );
  }

  TaskState? getTask(String taskId) => _tasks[taskId];

  NodeState? getNode(String nodeId) => _nodes[nodeId];

  ProjectState defaultProjectForNode(String nodeId) {
    final node = _nodes[nodeId];
    final path = _projectPathFromNode(node);
    return ProjectState(
      id: _projectId(nodeId, path),
      nodeId: nodeId,
      path: path,
      name: _projectName(path),
      sessionCount: sessionsForProject(nodeId, _projectId(nodeId, path)).length,
      lastSeenAt: node?.lastSeenAt,
    );
  }

  List<ProjectState> projectsForNode(String nodeId) {
    final node = _nodes[nodeId];
    final projects = <String, ProjectState>{};

    void put(ProjectState project) {
      projects[project.id] = project;
    }

    final defaultProject = defaultProjectForNode(nodeId);
    put(defaultProject);

    for (final task in _tasks.values.where((task) => task.nodeId == nodeId)) {
      put(
        ProjectState(
          id: task.projectId,
          nodeId: nodeId,
          path: task.projectPath,
          name: _projectName(task.projectPath),
          sessionCount: sessionsForProject(nodeId, task.projectId).length,
          lastSeenAt: task.createdAt,
        ),
      );
    }

    final result =
        projects.values.map((project) {
          final sessions = sessionsForProject(nodeId, project.id);
          return ProjectState(
            id: project.id,
            nodeId: project.nodeId,
            path: project.path,
            name: project.name,
            sessionCount: sessions.length,
            lastSeenAt: sessions.isNotEmpty
                ? sessions.first.updatedAt
                : node?.lastSeenAt,
          );
        }).toList()..sort((a, b) {
          final aTime = a.lastSeenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bTime = b.lastSeenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bTime.compareTo(aTime);
        });
    return List.unmodifiable(result);
  }

  List<ProjectSessionState> sessionsForProject(
    String nodeId,
    String projectId,
  ) {
    final sessions = <String, ProjectSessionState>{};
    final node = _nodes[nodeId];
    final activeSessionId = _sessionIdForNode(nodeId);
    final defaultProjectId = _projectId(nodeId, _projectPathFromNode(node));

    for (final task in _tasks.values.where(
      (task) => task.nodeId == nodeId && task.projectId == projectId,
    )) {
      final sessionId = task.sessionId ?? task.id;
      sessions[sessionId] = ProjectSessionState(
        id: sessionId,
        nodeId: nodeId,
        projectId: projectId,
        title: task.title,
        status: task.status,
        updatedAt: task.createdAt,
        task: task,
      );
    }

    if (activeSessionId != null && projectId == defaultProjectId) {
      sessions.putIfAbsent(
        activeSessionId,
        () => ProjectSessionState(
          id: activeSessionId,
          nodeId: nodeId,
          projectId: projectId,
          title: 'Pi session ${_shortId(activeSessionId)}',
          status: node?.online == true ? 'running' : 'idle',
          updatedAt: node?.lastSeenAt,
        ),
      );
    }

    final result = sessions.values.toList()
      ..sort((a, b) {
        final aTime = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });
    return List.unmodifiable(result);
  }

  void _markAllOffline() {
    for (final entry in _nodes.entries) {
      _nodes[entry.key] = entry.value.copyWith(online: false);
    }
    notifyListeners();
  }

  void _syncPiSessions(String nodeId, List<PiSessionInfo> sessions) {
    for (final session in sessions) {
      final taskId = _piSessionTaskId(nodeId, session.id);
      final existing = _tasks[taskId];
      if (existing?.status == 'running') continue;

      final projectPath = session.cwd.trim().isEmpty
          ? _projectPathFromNode(_nodes[nodeId])
          : session.cwd.trim();
      final title = session.displayTitle;
      _tasks[taskId] = TaskState(
        id: taskId,
        nodeId: nodeId,
        projectId: _projectId(nodeId, projectPath),
        projectPath: projectPath,
        sessionId: session.id,
        sessionPath: session.path,
        title: title.length > 80 ? '${title.substring(0, 80)}...' : title,
        status: 'history',
        messages: session.messages,
        createdAt: session.updatedAt,
      );
    }
    _pruneOldTasks();
  }

  void _pruneOldTasks() {
    const maxTasks = 200;
    if (_tasks.length <= maxTasks) return;
    final toRemove = _tasks.entries
        .where((e) => e.value.status != 'running')
        .map((e) => e.key)
        .take(_tasks.length - maxTasks)
        .toList();
    for (final key in toRemove) {
      _tasks.remove(key);
    }
  }

  void _notifyNow() {
    _streamingNotifyTimer?.cancel();
    _streamingNotifyTimer = null;
    notifyListeners();
  }

  void _notifyStreamingSoon() {
    if (_streamingNotifyTimer?.isActive == true) return;
    _streamingNotifyTimer = Timer(const Duration(milliseconds: 80), () {
      _streamingNotifyTimer = null;
      notifyListeners();
    });
  }

  void _restoreCursors(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    _cursorsByNode.clear();
    for (final nodeEntry in decoded.entries) {
      final nodeId = nodeEntry.key?.toString();
      final streams = nodeEntry.value;
      if (nodeId == null || nodeId.isEmpty || streams is! Map) continue;
      final nodeCursors = <String, int>{};
      for (final streamEntry in streams.entries) {
        final streamId = streamEntry.key?.toString();
        final seq = _intValue(streamEntry.value);
        if (streamId != null && streamId.isNotEmpty && seq != null) {
          nodeCursors[streamId] = seq;
        }
      }
      _cursorsByNode[nodeId] = nodeCursors;
    }
  }

  void _scheduleCursorSave() {
    if (_cursorSaveTimer?.isActive == true) return;
    _cursorSaveTimer = Timer(const Duration(seconds: 1), () {
      _cursorSaveTimer = null;
      unawaited(_persistCursors());
    });
  }

  Future<void> _persistCursors() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCursorPrefKey, jsonEncode(_cursorsByNode));
    } catch (_) {
      // Cursor persistence is an optimization; replay still works in-memory.
    }
  }

  String _normalizeNodeId(String from) {
    if (from.startsWith('node:')) return from.substring('node:'.length);
    return from;
  }

  int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  String _projectPathFromNode(NodeState? node) {
    final state = node?.piState;
    final project = state?['project'];
    final candidates = <Object?>[
      state?['projectPath'],
      state?['projectDir'],
      state?['cwd'],
      state?['workingDirectory'],
      state?['workspace'],
      if (project is Map) project['path'],
      if (project is Map) project['dir'],
    ];

    for (final candidate in candidates) {
      final value = candidate?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return 'Current Project';
  }

  String? _sessionIdForNode(String nodeId) {
    final state = _nodes[nodeId]?.piState;
    final sessionId = state?['sessionId']?.toString().trim();
    return sessionId == null || sessionId.isEmpty ? null : sessionId;
  }

  String _projectId(String nodeId, String path) => '$nodeId::$path';

  String _piSessionTaskId(String nodeId, String sessionId) =>
      'pi-session:$nodeId:$sessionId';

  static String _projectName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    if (trimmed.isEmpty) return path;
    return trimmed.split('/').last;
  }

  static String _shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

  @override
  void dispose() {
    _streamingNotifyTimer?.cancel();
    _cursorSaveTimer?.cancel();
    unawaited(_persistCursors());
    _messageSub.cancel();
    _connectionSub.cancel();
    _ws.dispose();
    super.dispose();
  }
}
