import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilepi_client/services/websocket_service.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';

void main() {
  group('WebSocketService heartbeat contract', () {
    test('detects half-open connections within about 30 seconds', () {
      expect(WebSocketService.heartbeatInterval, const Duration(seconds: 15));
      expect(WebSocketService.maxMissedPongs, 2);
    });

    test('closes a half-open connection after missed pongs', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var pingCount = 0;
      final sawTwoPings = Completer<void>();
      final sockets = <WebSocket>[];
      final serverSub = server.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((data) {
          if (data is String && data.contains('"type":"ping"')) {
            pingCount++;
            if (pingCount >= 2 && !sawTwoPings.isCompleted) {
              sawTwoPings.complete();
            }
          }
        });
      });
      final service = WebSocketService(
        hubUrl: 'ws://127.0.0.1:${server.port}/ws',
        tenantKey: 'tenant-a',
        heartbeatInterval: const Duration(milliseconds: 20),
        maxMissedPongs: 2,
      );

      final states = <bool>[];
      final stateSub = service.connectionStream.listen(states.add);
      service.connect();

      await expectLater(
        service.connectionStream,
        emitsInOrder(<bool>[true, false]),
      ).timeout(const Duration(seconds: 3));
      await sawTwoPings.future.timeout(const Duration(seconds: 3));

      expect(service.isConnected, isFalse);
      expect(states, containsAllInOrder(<bool>[true, false]));

      await stateSub.cancel();
      service.dispose();
      for (final socket in sockets) {
        await socket.close();
      }
      await serverSub.cancel();
      await server.close(force: true);
    });

    test('keeps a healthy connection alive when pongs arrive', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var pingCount = 0;
      final sawThreePings = Completer<void>();
      final sockets = <WebSocket>[];
      final serverSub = server.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((data) {
          if (data is String && data.contains('"type":"ping"')) {
            pingCount++;
            if (socket.readyState == WebSocket.open) {
              try {
                socket.add(
                  jsonEncode(
                    MobilePiMessage(
                      messageId: 'pong-$pingCount',
                      from: 'hub',
                      to: 'client',
                      type: MessageType.pong,
                      payload: const {},
                      timestamp: DateTime.utc(2026, 1, 1),
                    ).toJson(),
                  ),
                );
              } on StateError {
                return;
              }
            }
            if (pingCount >= 3 && !sawThreePings.isCompleted) {
              sawThreePings.complete();
            }
          }
        });
      });
      final service = WebSocketService(
        hubUrl: 'ws://127.0.0.1:${server.port}/ws',
        tenantKey: 'tenant-a',
        heartbeatInterval: const Duration(milliseconds: 20),
        maxMissedPongs: 2,
      );

      final states = <bool>[];
      final stateSub = service.connectionStream.listen(states.add);
      service.connect();

      await expectLater(
        service.connectionStream,
        emits(true),
      ).timeout(const Duration(seconds: 3));
      await sawThreePings.future.timeout(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(service.isConnected, isTrue);
      expect(states, isNot(contains(false)));

      await stateSub.cancel();
      service.dispose();
      for (final socket in sockets) {
        await socket.close();
      }
      await serverSub.cancel();
      await server.close(force: true);
    });
  });

  group('WebSocketService.normalizeHubUrl', () {
    test('keeps IPv4 host/path', () {
      expect(
        WebSocketService.normalizeHubUrl('ws://127.0.0.1:8080/ws'),
        'ws://127.0.0.1:8080/ws',
      );
    });

    test('adds /ws when path missing', () {
      expect(
        WebSocketService.normalizeHubUrl('example.com:42040'),
        'ws://example.com:42040/ws',
      );
    });

    test('preserves IPv6 brackets', () {
      expect(
        WebSocketService.normalizeHubUrl(
          'ws://[205:a02b:af52:1080:95:1601:4204:8a51]:42040/ws',
        ),
        'ws://[205:a02b:af52:1080:95:1601:4204:8a51]:42040/ws',
      );
    });
  });
}
