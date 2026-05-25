import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';

/// MobilePi 中枢服务器
class HubServer {
  final int port;
  final String host;
  final String tenantKey;
  HttpServer? _server;
  final Logger _logger = Logger('HubServer');
  final Map<String, WebSocketChannel> _clients = {};
  final Map<String, WebSocketChannel> _daemons = {};
  final Map<String, Map<String, dynamic>> _nodeSummaries = {};
  final Map<WebSocketChannel, String> _daemonIdsByChannel = {};
  final Map<WebSocketChannel, String> _clientIdsByChannel = {};
  String? _activeClientId;
  int _peerSeq = 0;
  int _messageSeq = 0;

  HubServer({required this.port, required String tenantKey, this.host = '0.0.0.0'})
    : tenantKey = _normalizeTenantKey(tenantKey) {
    if (this.tenantKey.isEmpty) {
      throw ArgumentError.value(tenantKey, 'tenantKey', 'must not be empty');
    }
  }

  int? get boundPort => _server?.port;

  String get wsUrl {
    final bound = boundPort;
    if (bound == null) {
      throw StateError('Hub server is not started');
    }
    // Return host-specific ws URL or fallback to localhost/127.0.0.1
    final displayHost = (host == '0.0.0.0' || host == '::') ? '127.0.0.1' : host;
    final urlHost = displayHost.contains(':') && !displayHost.startsWith('[')
        ? '[$displayHost]'
        : displayHost;
    return 'ws://$urlHost:$bound/ws';
  }

  Future<void> start() async {
    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(_router);

    _server = await shelf_io.serve(handler, host, port);
    _logger.info(
      'event=hub.started ${logFields({'address': _server!.address.host, 'port': _server!.port, 'wsUrl': wsUrl})}',
    );
  }

  Future<void> shutdown() async {
    for (final channel in [..._clients.values, ..._daemons.values]) {
      await channel.sink.close();
    }
    _clients.clear();
    _daemons.clear();
    _nodeSummaries.clear();
    _daemonIdsByChannel.clear();
    _clientIdsByChannel.clear();
    _activeClientId = null;
    await _server?.close(force: true);
    _logger.info('event=hub.stopped');
  }

  FutureOr<Response> _router(Request request) {
    if (request.url.path == 'ws') {
      return webSocketHandler(_handleSocket)(request);
    }
    return Response.ok('MobilePi Hub OK - ${DateTime.now().toIso8601String()}');
  }

  void _handleSocket(WebSocketChannel channel) {
    final peerId = 'peer-${++_peerSeq}';
    _logger.info('event=ws.connected ${logField('peerId', peerId)}');

    channel.stream.listen(
      (data) => _handleMessage(peerId, channel, data),
      onDone: () => _removePeer(channel),
      onError: (Object e) {
        _logger.warning('event=ws.error ${logField('peerId', peerId)}', e);
        _removePeer(channel);
      },
    );
  }

  void _handleMessage(String peerId, WebSocketChannel channel, dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      final message = MobilePiMessage.fromJson(json);
      _logger.fine(
        'event=ws.receive ${logField('peerId', peerId)} ${summarizeMessage(message)}',
      );

      switch (message.type) {
        case MessageType.hello:
          _handleHello(channel, message);
          break;
        case MessageType.ping:
          _sendPong(channel, message);
          break;
        default:
          _routeMessage(channel, message);
      }
    } catch (e, st) {
      _logger.warning(
        'event=ws.message_error ${logField('peerId', peerId)}',
        e,
        st,
      );
    }
  }

  void _handleHello(WebSocketChannel channel, MobilePiMessage message) {
    if (!_isAuthorized(message)) {
      _rejectUnauthorizedHello(channel, message);
      return;
    }

    final nodeId = _nodeIdFromMessage(message);
    if (nodeId != null && nodeId.isNotEmpty) {
      _registerOrUpdateDaemon(channel, message);
      return;
    }

    final clientId =
        message.payload['clientId']?.toString().trim().isNotEmpty == true
        ? message.payload['clientId'].toString()
        : message.from;
    _registerClient(channel, clientId);
    _sendMessage(
      channel,
      MobilePiMessage(
        messageId: _nextMessageId(),
        from: 'hub',
        to: 'client',
        type: MessageType.response,
        payload: {
          ProtocolPayloadKeys.responseTo: message.messageId,
          ProtocolPayloadKeys.nodeSummaries: _nodeSummaries.values
              .map((summary) => Map<String, dynamic>.from(summary))
              .toList(),
        },
      ),
    );
  }

  void _registerClient(WebSocketChannel channel, String clientId) {
    final previousId = _clientIdsByChannel[channel];
    if (previousId == clientId) return;
    if (previousId != null) {
      _clients.remove(previousId);
    }
    final activeClientId = _activeClientId;
    if (activeClientId != null && activeClientId != clientId) {
      final oldClient = _clients.remove(activeClientId);
      if (oldClient != null && !identical(oldClient, channel)) {
        unawaited(oldClient.sink.close());
      }
    }
    _clientIdsByChannel[channel] = clientId;
    _clients[clientId] = channel;
    _activeClientId = clientId;
    _logger.info(
      'event=client.registered ${logFields({'clientId': clientId, 'replacedClientId': activeClientId == null || activeClientId == clientId ? null : activeClientId})}',
    );
  }

  void _registerOrUpdateDaemon(
    WebSocketChannel channel,
    MobilePiMessage message,
  ) {
    final nodeId = _nodeIdFromMessage(message) ?? message.from;
    if (nodeId.isEmpty) {
      _logger.warning(
        'event=daemon.registration_failed reason=missing_node_id',
      );
      return;
    }

    final previousId = _daemonIdsByChannel[channel];
    if (previousId != null && previousId != nodeId) {
      _daemons.remove(previousId);
      _nodeSummaries.remove(previousId);
    }

    _daemonIdsByChannel[channel] = nodeId;
    _daemons[nodeId] = channel;

    final payload = Map<String, dynamic>.from(message.payload)
      ..remove(ProtocolPayloadKeys.tenantKey);
    payload[ProtocolPayloadKeys.nodeId] = nodeId;
    payload[ProtocolPayloadKeys.online] = true;
    _nodeSummaries[nodeId] = payload;
    _logger.info(
      'event=daemon.registered ${logFields({'nodeId': nodeId, 'hostname': payload[ProtocolPayloadKeys.hostname], 'agents': (payload[ProtocolPayloadKeys.agents] as Object?)?.toString()})}',
    );

    if (message.type == MessageType.hello || message.to == null) {
      _broadcastNodeSummaries([payload]);
    } else {
      final client = _clients[message.to!];
      if (client != null) {
        _sendNodeSummaries(client, message.messageId, [payload]);
      }
    }
  }

  void _routeMessage(WebSocketChannel channel, MobilePiMessage message) {
    if (!_isRegisteredChannel(channel)) {
      _logger.warning(
        'event=route.drop reason=unauthenticated_peer ${summarizeMessage(message)}',
      );
      _sendMessage(
        channel,
        MobilePiMessage(
          messageId: _nextMessageId(),
          from: 'hub',
          to: message.from,
          type: MessageType.error,
          payload: {
            ProtocolPayloadKeys.responseTo: message.messageId,
            'code': 'unauthenticated_peer',
          },
        ),
      );
      return;
    }

    final target = message.to;
    if (target == null || target.isEmpty) {
      _logger.warning(
        'event=route.drop reason=missing_target ${summarizeMessage(message)}',
      );
      return;
    }

    final normalizedNodeTarget = _normalizeNodeTarget(target);
    final daemon = normalizedNodeTarget == null
        ? null
        : _daemons[normalizedNodeTarget];
    if (daemon != null) {
      _sendMessage(daemon, message);
      return;
    }

    final normalizedClientTarget = _normalizeClientTarget(target);
    final client = normalizedClientTarget == null
        ? null
        : _clients[normalizedClientTarget];
    if (client != null) {
      _sendMessage(client, message);
      return;
    }

    _logger.warning(
      'event=route.miss ${logField('target', target)} ${summarizeMessage(message)}',
    );
  }

  void _sendPong(WebSocketChannel channel, MobilePiMessage ping) {
    _sendMessage(
      channel,
      MobilePiMessage(
        messageId: _nextMessageId(),
        from: 'hub',
        to: ping.from,
        type: MessageType.pong,
        payload: const {},
      ),
    );
  }

  void _sendMessage(WebSocketChannel channel, MobilePiMessage message) {
    try {
      _logger.fine('event=ws.send ${summarizeMessage(message)}');
      channel.sink.add(jsonEncode(message.toJson()));
    } catch (e) {
      _logger.warning('event=ws.send_failed ${summarizeMessage(message)}', e);
    }
  }

  void _removePeer(WebSocketChannel channel) {
    final clientId = _clientIdsByChannel.remove(channel);
    if (clientId != null) {
      _clients.remove(clientId);
      if (_activeClientId == clientId) {
        _activeClientId = null;
      }
      _logger.info(
        'event=client.disconnected ${logField('clientId', clientId)}',
      );
    }

    final daemonId = _daemonIdsByChannel.remove(channel);
    if (daemonId != null) {
      _daemons.remove(daemonId);
      final summary = _nodeSummaries.remove(daemonId);
      _logger.info('event=daemon.disconnected ${logField('nodeId', daemonId)}');
      if (summary != null) {
        final payload = Map<String, dynamic>.from(summary);
        payload[ProtocolPayloadKeys.online] = false;
        _broadcastNodeSummaries([payload]);
      }
    }
  }

  void _broadcastNodeSummaries(List<Map<String, dynamic>> summaries) {
    for (final client in _clients.values) {
      _sendNodeSummaries(client, _nextMessageId(), summaries);
    }
  }

  void _sendNodeSummaries(
    WebSocketChannel channel,
    String responseTo,
    List<Map<String, dynamic>> summaries,
  ) {
    _sendMessage(
      channel,
      MobilePiMessage(
        messageId: _nextMessageId(),
        from: 'hub',
        to: 'client',
        type: MessageType.response,
        payload: {
          ProtocolPayloadKeys.responseTo: responseTo,
          ProtocolPayloadKeys.nodeSummaries: summaries,
        },
      ),
    );
  }

  String? _nodeIdFromMessage(MobilePiMessage message) {
    final payloadNodeId = message.payload[ProtocolPayloadKeys.nodeId]
        ?.toString();
    if (payloadNodeId != null && payloadNodeId.isNotEmpty) {
      return payloadNodeId;
    }
    return _normalizeNodeTarget(message.from);
  }

  String? _normalizeNodeTarget(String target) {
    if (!target.startsWith('node:')) return null;
    return target.substring('node:'.length);
  }

  String? _normalizeClientTarget(String target) {
    if (target != 'client') return null;
    return _activeClientId;
  }

  bool _isAuthorized(MobilePiMessage message) {
    final submittedKey = message.payload[ProtocolPayloadKeys.tenantKey]
        ?.toString();
    return _normalizeTenantKey(submittedKey) == tenantKey;
  }

  bool _isRegisteredChannel(WebSocketChannel channel) =>
      _clientIdsByChannel.containsKey(channel) ||
      _daemonIdsByChannel.containsKey(channel);

  void _rejectUnauthorizedHello(
    WebSocketChannel channel,
    MobilePiMessage message,
  ) {
    final peerKind = _nodeIdFromMessage(message) == null ? 'client' : 'daemon';
    _logger.warning(
      'event=auth.reject ${logFields({'peerKind': peerKind, 'reason': 'invalid_tenant_key'})} ${summarizeMessage(message)}',
    );
    _sendMessage(
      channel,
      MobilePiMessage(
        messageId: _nextMessageId(),
        from: 'hub',
        to: message.from,
        type: MessageType.error,
        payload: {
          ProtocolPayloadKeys.responseTo: message.messageId,
          'code': 'invalid_tenant_key',
        },
      ),
    );
    unawaited(channel.sink.close());
  }

  static String _normalizeTenantKey(String? key) => key?.trim() ?? '';

  String _nextMessageId() => 'hub-${++_messageSeq}';
}
