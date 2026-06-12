import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilepi_client/providers/node_provider.dart';
import 'package:mobilepi_client/screens/dashboard_screen.dart';
import 'package:mobilepi_client/services/session_cache.dart';
import 'package:mobilepi_client/services/websocket_service.dart';
import 'package:mobilepi_client/theme/app_tokens.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('drawer keeps utility entries without exposing Kanban', (
    tester,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => NodeProvider(
          webSocketService: _FakeWebSocketService(),
          sessionCache: SessionCache.inMemory(),
        ),
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: AppTokens.light.brandSeed,
            ),
            extensions: const [AppTokens.light],
          ),
          home: const DashboardScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Grill Me (需求确认)'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('日志'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('Kanban'), findsNothing);
    expect(find.byIcon(Icons.view_kanban_rounded), findsNothing);
  });

  testWidgets('waiting tasks expose inline decision actions on home', (
    tester,
  ) async {
    final ws = _FakeWebSocketService();
    final provider = NodeProvider(
      webSocketService: ws,
      sessionCache: SessionCache.inMemory(),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => provider,
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: AppTokens.light.brandSeed,
            ),
            extensions: const [AppTokens.light],
          ),
          home: const DashboardScreen(),
        ),
      ),
    );

    ws.emitNodeSummary();
    await tester.pump();

    provider.sendTaskCommand('fix the flaky test', nodeId: 'node-1');
    final taskId = ws.taskCreateRequests.single['taskId'] as String;
    ws.emitTaskStatus(taskId, 'waitingDecision');
    await tester.pumpAndSettle();

    expect(find.text('等待决策'), findsOneWidget);
    expect(find.text('查看'), findsOneWidget);
    expect(find.text('换思路'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);

    await tester.tap(find.text('换思路'));
    await tester.pump();

    expect(ws.steerRequests, hasLength(1));
    expect(ws.steerRequests.single['taskId'], taskId);
    expect(ws.steerRequests.single['message'], contains('请换一种思路继续'));
  });

  testWidgets(
    'task cards use long-press action sheets instead of swipe delete',
    (tester) async {
      final ws = _FakeWebSocketService();
      final provider = NodeProvider(
        webSocketService: ws,
        sessionCache: SessionCache.inMemory(),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => provider,
          child: MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: AppTokens.light.brandSeed,
              ),
              extensions: const [AppTokens.light],
            ),
            home: const DashboardScreen(),
          ),
        ),
      );

      ws.emitNodeSummary();
      await tester.pump();

      provider.sendTaskCommand('long press task', nodeId: 'node-1');
      final taskId = ws.taskCreateRequests.single['taskId'] as String;
      ws.emitTaskStatus(taskId, 'running');
      await tester.pumpAndSettle();

      expect(find.byType(Dismissible), findsNothing);

      await tester.longPress(find.text('long press task').first);
      await tester.pumpAndSettle();

      expect(find.text('查看会话'), findsOneWidget);
      expect(find.text('查看日志'), findsOneWidget);
      expect(find.text('紧急停止'), findsOneWidget);
      expect(find.text('移除本地记录'), findsOneWidget);

      await tester.tap(find.text('紧急停止'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('终止'));
      await tester.pumpAndSettle();

      expect(ws.panicRequests, hasLength(1));
      expect(ws.panicRequests.single['taskId'], taskId);
    },
  );
}

class _FakeWebSocketService extends WebSocketService {
  final StreamController<MobilePiMessage> _messages =
      StreamController<MobilePiMessage>.broadcast();
  final StreamController<bool> _connections =
      StreamController<bool>.broadcast();
  final List<Map<String, dynamic>> taskCreateRequests = [];
  final List<Map<String, dynamic>> steerRequests = [];
  final List<Map<String, dynamic>> panicRequests = [];

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
    _connections.add(false);
  }

  @override
  void sendTaskCommand(
    String nodeId,
    String taskId,
    String prompt, {
    String agentType = 'pi',
    String? piInstanceId,
    String? model,
    String? projectPath,
  }) {
    taskCreateRequests.add({
      'nodeId': nodeId,
      'taskId': taskId,
      'prompt': prompt,
    });
  }

  @override
  void sendSteerCommand(
    String nodeId,
    String taskId,
    String message, {
    String? sessionPath,
    String? model,
  }) {
    steerRequests.add({'nodeId': nodeId, 'taskId': taskId, 'message': message});
  }

  @override
  void sendPanic(String nodeId, {String? taskId}) {
    panicRequests.add({'nodeId': nodeId, 'taskId': taskId});
  }

  void emitNodeSummary() {
    _messages.add(
      MobilePiMessage(
        messageId: 'node-summary',
        from: 'hub',
        to: 'client',
        type: MessageType.response,
        payload: {
          ProtocolPayloadKeys.nodeSummary: {
            ProtocolPayloadKeys.nodeId: 'node-1',
            ProtocolPayloadKeys.hostname: 'macbook',
            ProtocolPayloadKeys.platform: 'macos',
            ProtocolPayloadKeys.agents: ['pi'],
            ProtocolPayloadKeys.online: true,
          },
        },
        timestamp: DateTime.utc(2026, 1, 1),
      ),
    );
  }

  void emitTaskStatus(String taskId, String status) {
    _messages.add(
      MobilePiMessage(
        messageId: 'task-status-$taskId-$status',
        from: 'node:node-1',
        to: 'client',
        type: MessageType.event,
        payload: {
          ProtocolPayloadKeys.streamId: 'task:$taskId',
          ProtocolPayloadKeys.seq: 1,
          ProtocolPayloadKeys.eventType: 'task.status',
          ProtocolPayloadKeys.eventPayload: {
            'taskId': taskId,
            'status': status,
          },
          ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:00.000Z',
        },
        timestamp: DateTime.utc(2026, 1, 1),
      ),
    );
  }

  @override
  void dispose() {
    _messages.close();
    _connections.close();
  }
}
