import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';

import 'ws_connect.dart';

/// Client 端 WebSocket 连接服务
///
/// - 连接 Hub，而不是直接连接 Daemon
/// - 心跳间隔 30s，超时判定 3 次未收到 pong
/// - 断线自动重连（指数退避，最大 30s）
class WebSocketService {
  static const String _configuredHubUrl = String.fromEnvironment(
    'MOBILE_PI_HUB_WS_URL',
  );
  static const String _configuredTenantKey = String.fromEnvironment(
    'MOBILE_PI_TENANT_KEY',
  );
  static const String _defaultHubUrl = 'ws://localhost:8080/ws';
  static const Duration _heartbeatInterval = Duration(seconds: 30);
  static const int _maxMissedPongs = 3;
  static const Duration _initialBackoff = Duration(seconds: 1);
  static const Duration _maxBackoff = Duration(seconds: 30);

  final Logger _logger = Logger('WebSocketService');

  WebSocketChannel? _channel;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;

  bool _connected = false;
  int _missedPongs = 0;
  Duration _backoff = _initialBackoff;
  final String _clientId = 'client-${const Uuid().v4()}';
  late String _wsUrl;
  String _tenantKey = _configuredTenantKey.trim();

  final StreamController<MobilePiMessage> _messageController =
      StreamController<MobilePiMessage>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  Stream<MobilePiMessage> get messageStream => _messageController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  bool get isConnected => _connected;

  WebSocketService({String? hubUrl, String? tenantKey}) {
    _wsUrl = normalizeHubUrl(hubUrl ?? defaultHubUrl());
    if (tenantKey != null) {
      _tenantKey = normalizeTenantKey(tenantKey);
    }
  }

  String get hubUrl => _wsUrl;
  String get tenantKey => _tenantKey;

  /// 更新 Hub URL（会立即断开当前连接，由调用方决定何时 reconnect）。
  /// 返回归一化后的最终 URL。如果 URL 解析失败会抛 [FormatException]。
  String updateHubUrl(String url) {
    final normalized = normalizeHubUrl(url);
    if (normalized == _wsUrl) return normalized;
    _wsUrl = normalized;
    if (_connected || _channel != null) {
      disconnect();
    }
    return normalized;
  }

  String updateTenantKey(String key) {
    final normalized = normalizeTenantKey(key);
    if (normalized == _tenantKey) return normalized;
    _tenantKey = normalized;
    if (_connected || _channel != null) {
      disconnect();
    }
    return normalized;
  }

  static String defaultTenantKey() => _configuredTenantKey.trim();

  static String normalizeTenantKey(String key) => key.trim();

  static String defaultHubUrl() {
    if (_configuredHubUrl.trim().isNotEmpty) {
      return _configuredHubUrl;
    }
    return _defaultHubUrl;
  }

  static String normalizeHubUrl(String url) {
    var trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('URL 不能为空');
    }

    // Check if it already has a scheme
    final schemeMatch = RegExp(
      r'^([a-zA-Z]+)://',
      caseSensitive: false,
    ).firstMatch(trimmed);
    String scheme;
    String remainder;
    if (schemeMatch != null) {
      final parsedScheme = schemeMatch.group(1)!.toLowerCase();
      if (parsedScheme == 'https' || parsedScheme == 'wss') {
        scheme = 'wss';
      } else if (parsedScheme == 'http' || parsedScheme == 'ws') {
        scheme = 'ws';
      } else {
        throw const FormatException('URL scheme 必须是 ws/wss/http/https');
      }
      remainder = trimmed.substring(schemeMatch.end);
    } else {
      scheme = 'ws';
      remainder = trimmed;
    }

    final uri = Uri.parse('$scheme://$remainder');
    if (uri.host.isEmpty) {
      throw FormatException('无效的 URL: $url');
    }

    final normalizedHost = uri.host.contains(':') ? '[${uri.host}]' : uri.host;

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

  void connect() {
    if (_tenantKey.isEmpty) {
      _logger.warning('event=ws.connect_blocked reason=missing_tenant_key');
      _connectionController.add(false);
      return;
    }
    _logger.info(
      'event=ws.connect_start ${logFields({'url': _wsUrl, 'clientId': _clientId})}',
    );
    _cancelReconnect();
    unawaited(_openChannel());
  }

  Future<void> _openChannel() async {
    try {
      final channel = await connectWs(_wsUrl);
      _channel = channel;

      channel.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: (e) {
          _logger.warning('event=ws.error ${logField('url', _wsUrl)}', e);
          _onDisconnected();
        },
      );

      _connected = true;
      _missedPongs = 0;
      _backoff = _initialBackoff;
      _connectionController.add(true);
      _logger.info(
        'event=ws.connected ${logFields({'url': _wsUrl, 'clientId': _clientId})}',
      );
      _startHeartbeat();
    } catch (e, st) {
      _logger.warning(
        'event=ws.connect_failed ${logField('url', _wsUrl)}',
        e,
        st,
      );
      _connected = false;
      _channel = null;
      _connectionController.add(false);
      _scheduleReconnect();
    }
  }

  void disconnect() {
    _logger.info('event=ws.disconnect_requested ${logField('url', _wsUrl)}');
    _cancelHeartbeat();
    _cancelReconnect();
    _connected = false;
    _connectionController.add(false);
    _channel?.sink.close();
    _channel = null;
  }

  /// 立即重连：用于 app 从后台切回前台。移动端被系统冻结后 socket 常已成僵尸
  /// （`onDone` 未触发，`_connected` 仍为 true），故先强制断开再立刻重连，
  /// 并复位退避，避免干等退避定时器。
  void forceReconnect() {
    _logger.info('event=ws.force_reconnect ${logField('url', _wsUrl)}');
    _cancelHeartbeat();
    _cancelReconnect();
    _backoff = _initialBackoff;
    _connected = false;
    _channel?.sink.close();
    _channel = null;
    connect();
  }

  void _onMessage(dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      final message = MobilePiMessage.fromJson(json);

      if (message.type == MessageType.pong) {
        _missedPongs = 0;
        _logger.fine('event=ws.pong ${summarizeMessage(message)}');
        return;
      }

      _logger.info('event=ws.receive ${summarizeMessage(message)}');
      _messageController.add(message);
    } catch (e, st) {
      _logger.warning('event=ws.message_error', e, st);
    }
  }

  void _onDisconnected() {
    if (!_connected) return;
    _logger.info('event=ws.disconnected ${logField('url', _wsUrl)}');
    _connected = false;
    _connectionController.add(false);
    _cancelHeartbeat();
    _scheduleReconnect();
  }

  void _startHeartbeat() {
    _cancelHeartbeat();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (!_connected) return;

      if (_missedPongs >= _maxMissedPongs) {
        _logger.warning(
          'event=ws.heartbeat_timeout ${logFields({'missedPongs': _missedPongs, 'maxMissedPongs': _maxMissedPongs})}',
        );
        _channel?.sink.close();
        _onDisconnected();
        return;
      }

      _sendPing();
      _missedPongs++;
    });
  }

  void _cancelHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _scheduleReconnect() {
    _cancelReconnect();
    _logger.info(
      'event=ws.reconnect_scheduled ${logFields({'delayMs': _backoff.inMilliseconds, 'url': _wsUrl})}',
    );
    final jitter = Duration(milliseconds: Random().nextInt(1000));
    _reconnectTimer = Timer(_backoff + jitter, connect);

    // 指数退避
    _backoff = Duration(
      milliseconds: (_backoff.inMilliseconds * 2).clamp(
        _initialBackoff.inMilliseconds,
        _maxBackoff.inMilliseconds,
      ),
    );
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _sendPing() {
    final message = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: _clientId,
      type: MessageType.ping,
      payload: {},
    );
    _logger.fine('event=ws.ping ${summarizeMessage(message)}');
    _send(message);
  }

  void sendHello({Map<String, Map<String, int>> lastCursors = const {}}) {
    final payload = <String, dynamic>{
      'clientId': _clientId,
      'deviceName': 'MobilePi Client',
      'lastCursors': lastCursors,
      ProtocolPayloadKeys.tenantKey: _tenantKey,
    };
    final message = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: _clientId,
      to: 'hub',
      type: MessageType.hello,
      payload: payload,
    );
    _logger.info(
      'event=ws.hello_send ${logFields({'clientId': _clientId, 'url': _wsUrl, 'tenantKeySet': _tenantKey.isNotEmpty})}',
    );
    _send(message);
  }

  void sendResume(String nodeId, Map<String, int> cursors) {
    final message = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: _clientId,
      to: 'node:$nodeId',
      type: MessageType.resume,
      payload: {
        ProtocolPayloadKeys.cursors: cursors,
        ProtocolPayloadKeys.includeNodeSummary: true,
      },
    );
    _send(message);
  }

  void sendPanic(String nodeId, {String? taskId}) {
    final message = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: _clientId,
      to: 'node:$nodeId',
      type: MessageType.command,
      payload: {
        ProtocolPayloadKeys.commandType: 'task.panic',
        ProtocolPayloadKeys.requestId: const Uuid().v4(),
        'taskId': taskId,
      },
    );
    _send(message);
  }

  void sendTaskCommand(
    String nodeId,
    String taskId,
    String prompt, {
    String agentType = 'pi',
    String? piInstanceId,
    String? model,
    String? projectPath,
  }) {
    final payload = <String, dynamic>{
      'taskId': taskId,
      'agentType': agentType,
      'prompt': prompt,
    };
    if (model != null && model.isNotEmpty) {
      payload[ProtocolPayloadKeys.model] = model;
    }
    if (piInstanceId != null && piInstanceId.isNotEmpty) {
      payload[ProtocolPayloadKeys.piInstanceId] = piInstanceId;
    }
    if (projectPath != null && projectPath.isNotEmpty) {
      payload[ProtocolPayloadKeys.projectPath] = projectPath;
    }

    payload[ProtocolPayloadKeys.commandType] = 'task.create';
    payload[ProtocolPayloadKeys.requestId] = const Uuid().v4();

    final message = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: _clientId,
      to: 'node:$nodeId',
      type: MessageType.command,
      payload: payload,
    );
    _send(message);
  }

  void sendSteerCommand(
    String nodeId,
    String taskId,
    String message, {
    String? sessionPath,
    String? model,
  }) {
    final payload = <String, dynamic>{'taskId': taskId, 'message': message};
    if (sessionPath != null && sessionPath.isNotEmpty) {
      payload[ProtocolPayloadKeys.sessionPath] = sessionPath;
    }
    if (model != null && model.isNotEmpty) {
      payload[ProtocolPayloadKeys.model] = model;
    }
    payload[ProtocolPayloadKeys.commandType] = 'task.steer';
    payload[ProtocolPayloadKeys.requestId] = const Uuid().v4();
    final msg = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: _clientId,
      to: 'node:$nodeId',
      type: MessageType.command,
      payload: payload,
    );
    _send(msg);
  }

  void sendFollowUpCommand(
    String nodeId,
    String taskId,
    String message, {
    String? sessionPath,
    String? model,
  }) {
    final payload = <String, dynamic>{'taskId': taskId, 'message': message};
    if (sessionPath != null && sessionPath.isNotEmpty) {
      payload[ProtocolPayloadKeys.sessionPath] = sessionPath;
    }
    if (model != null && model.isNotEmpty) {
      payload[ProtocolPayloadKeys.model] = model;
    }
    payload[ProtocolPayloadKeys.commandType] = 'task.follow_up';
    payload[ProtocolPayloadKeys.requestId] = const Uuid().v4();
    final msg = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: _clientId,
      to: 'node:$nodeId',
      type: MessageType.command,
      payload: payload,
    );
    _send(msg);
  }

  /// Returns the messageId used to correlate the response.
  String sendBrowseDirectoryRequest(String nodeId, {String? path}) {
    final messageId = const Uuid().v4();
    final payload = <String, dynamic>{
      ProtocolPayloadKeys.commandType: 'directory.browse',
    };
    if (path != null && path.isNotEmpty) {
      payload[ProtocolPayloadKeys.path] = path;
    }
    final message = MobilePiMessage(
      messageId: messageId,
      from: _clientId,
      to: 'node:$nodeId',
      type: MessageType.query,
      payload: payload,
    );
    _send(message);
    return messageId;
  }

  /// Returns the messageId used to correlate the response.
  String sendCreateDirectoryRequest(
    String nodeId, {
    required String parentPath,
    required String name,
  }) {
    final messageId = const Uuid().v4();
    final message = MobilePiMessage(
      messageId: messageId,
      from: _clientId,
      to: 'node:$nodeId',
      type: MessageType.command,
      payload: {
        ProtocolPayloadKeys.commandType: 'directory.create',
        ProtocolPayloadKeys.requestId: messageId,
        ProtocolPayloadKeys.parentPath: parentPath,
        ProtocolPayloadKeys.name: name,
      },
    );
    _send(message);
    return messageId;
  }

  void sendSessionMessagesRequest(
    String nodeId,
    String sessionPath, {
    String? taskId,
    int limit = 20,
    int? beforeIndex,
  }) {
    final message = MobilePiMessage(
      messageId: const Uuid().v4(),
      from: _clientId,
      to: 'node:$nodeId',
      type: MessageType.query,
      payload: {
        ProtocolPayloadKeys.commandType: 'messages.list',
        'sessionPath': sessionPath,
        if (taskId != null && taskId.isNotEmpty) 'taskId': taskId,
        'limit': limit,
        'beforeIndex': ?beforeIndex,
      },
    );
    _send(message);
  }

  void _send(MobilePiMessage message) {
    try {
      _logger.fine('event=ws.send ${summarizeMessage(message)}');
      _channel?.sink.add(jsonEncode(message.toJson()));
    } catch (e) {
      _logger.warning('event=ws.send_failed ${summarizeMessage(message)}', e);
    }
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _connectionController.close();
  }
}
