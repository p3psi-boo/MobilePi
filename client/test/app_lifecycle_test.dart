import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilepi_client/app.dart';
import 'package:mobilepi_client/providers/node_provider.dart';
import 'package:mobilepi_client/services/session_cache.dart';
import 'package:mobilepi_client/services/websocket_service.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('foreground resume forces reconnect from app lifecycle', (
    tester,
  ) async {
    final ws = _LifecycleWebSocketService();
    final provider = NodeProvider(
      webSocketService: ws,
      sessionCache: SessionCache.inMemory(),
    );
    addTearDown(provider.dispose);
    final previousDebugPrint = debugPrint;
    final debugLines = <String>[];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) {
        debugLines.add(message);
      }
      previousDebugPrint(message, wrapWidth: wrapWidth);
    };

    await tester.pumpWidget(MobilePiApp(provider: provider));
    await tester.pumpAndSettle();

    ws.forceReconnectCount = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(ws.forceReconnectCount, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    debugPrint = previousDebugPrint;

    expect(ws.forceReconnectCount, 1);
    expect(debugLines, contains('MobilePiLifecycle event=app_paused'));
    expect(debugLines, contains('MobilePiLifecycle event=app_resumed'));
    expect(
      debugLines,
      contains('MobilePiLifecycle event=app_resumed action=force_reconnect'),
    );
  });
}

class _LifecycleWebSocketService extends WebSocketService {
  final StreamController<MobilePiMessage> _messages =
      StreamController<MobilePiMessage>.broadcast();
  final StreamController<bool> _connections =
      StreamController<bool>.broadcast();
  int forceReconnectCount = 0;

  @override
  Stream<MobilePiMessage> get messageStream => _messages.stream;

  @override
  Stream<bool> get connectionStream => _connections.stream;

  @override
  bool get isConnected => false;

  @override
  String get hubUrl => 'ws://localhost:8080/ws';

  @override
  String get tenantKey => 'tenant-a';

  @override
  void connect() {
    _connections.add(true);
  }

  @override
  void forceReconnect() {
    forceReconnectCount++;
    _connections.add(true);
  }

  @override
  void sendHello({Map<String, Map<String, int>> lastCursors = const {}}) {}

  @override
  void dispose() {
    _messages.close();
    _connections.close();
  }
}
