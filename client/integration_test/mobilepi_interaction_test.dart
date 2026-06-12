import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logging/logging.dart';
import 'package:mobilepi_client/providers/node_provider.dart';
import 'package:mobilepi_client/screens/dashboard_screen.dart';
import 'package:mobilepi_client/screens/task_detail_screen.dart';
import 'package:mobilepi_client/services/log_buffer.dart';
import 'package:mobilepi_client/services/session_cache.dart';
import 'package:mobilepi_client/services/websocket_service.dart';
import 'package:mobilepi_client/theme/app_tokens.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LogBuffer.instance.clear();
  });

  tearDown(() {
    LogBuffer.instance.clear();
  });

  testWidgets('mobile dashboard actions run on-device gesture paths', (
    tester,
  ) async {
    final ws = _FakeWebSocketService();
    final provider = NodeProvider(
      webSocketService: ws,
      sessionCache: SessionCache.inMemory(),
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(_InteractionHarness(provider: provider));
    ws.emitNodeSummary();
    await tester.pump();

    provider.sendTaskCommand('mobile waiting action', nodeId: 'node-1');
    final taskId = ws.taskCreateRequests.single['taskId'] as String;
    ws.emitTaskStatus(taskId, 'waitingDecision');
    await tester.pumpAndSettle();

    expect(find.text('等待决策'), findsOneWidget);
    expect(find.text('查看'), findsOneWidget);
    expect(find.text('换思路'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    expect(find.byType(Dismissible), findsNothing);

    await tester.tap(find.text('换思路'));
    await tester.pumpAndSettle();

    expect(ws.steerRequests, hasLength(1));
    expect(ws.steerRequests.single['taskId'], taskId);

    ws.emitTaskStatus(taskId, 'running', seq: 2);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('mobile waiting action').first);
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
  });

  testWidgets('task detail gestures keep mobile conversation controls usable', (
    tester,
  ) async {
    LogBuffer.instance.addForTesting(
      LogRecord(Level.INFO, 'device detail log entry', 'mobilepi.integration'),
    );

    final ws = _FakeWebSocketService();
    final provider = NodeProvider(
      webSocketService: ws,
      sessionCache: SessionCache.inMemory(),
    );
    addTearDown(provider.dispose);
    final taskId = provider.sendTaskCommand(
      'mobile detail gestures',
      nodeId: 'node-1',
    );

    await tester.pumpWidget(
      _InteractionHarness(
        provider: provider,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TaskDetailScreen(taskId: taskId),
                    ),
                  ),
                  child: const Text('Open detail'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open detail'));
    await tester.pumpAndSettle();

    expect(find.text('mobile detail gestures'), findsWidgets);

    final logHandleSize = tester.getSize(find.byTooltip('日志'));
    final sendButtonSize = tester.getSize(find.byTooltip('发送'));
    expect(logHandleSize.height, greaterThanOrEqualTo(44));
    expect(sendButtonSize.width, greaterThanOrEqualTo(44));
    expect(sendButtonSize.height, greaterThanOrEqualTo(44));

    await tester.tap(find.byTooltip('日志'));
    await tester.pumpAndSettle();

    expect(find.text('日志'), findsOneWidget);
    expect(find.textContaining('device detail log entry'), findsOneWidget);
    expect(find.textContaining('mobilepi.integration'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(4, 360), const Offset(160, 0));
    await tester.pumpAndSettle();

    expect(find.text('Open detail'), findsOneWidget);
    expect(find.text('mobile detail gestures'), findsNothing);
  });
}

class _InteractionHarness extends StatelessWidget {
  const _InteractionHarness({required this.provider, this.home});

  final NodeProvider provider;
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: provider,
      child: MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppTokens.light.brandSeed,
          ),
          extensions: const [AppTokens.light],
        ),
        home: home ?? const DashboardScreen(),
      ),
    );
  }
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

  void emitTaskStatus(String taskId, String status, {int seq = 1}) {
    _messages.add(
      MobilePiMessage(
        messageId: 'task-status-$taskId-$status-$seq',
        from: 'node:node-1',
        to: 'client',
        type: MessageType.event,
        payload: {
          ProtocolPayloadKeys.streamId: 'task:$taskId',
          ProtocolPayloadKeys.seq: seq,
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
