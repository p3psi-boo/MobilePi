import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilepi_client/providers/node_provider.dart';
import 'package:mobilepi_client/screens/task_create_screen.dart';
import 'package:mobilepi_client/screens/task_detail_screen.dart';
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

  testWidgets('new task starts as a blank conversation and opens detail', (
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
          home: const TaskCreateScreen(
            projectId: 'node-1::/repo/mobilepi',
            projectPath: '/repo/mobilepi',
          ),
        ),
      ),
    );

    ws.emitNodeSummary();
    await tester.pumpAndSettle();

    expect(find.text('新对话'), findsOneWidget);
    expect(find.text('说点什么？'), findsOneWidget);
    expect(find.text('发送消息…'), findsOneWidget);
    expect(find.byType(TaskDetailScreen), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.textContaining('Node'), findsNothing);
    expect(find.textContaining('Pi 模型'), findsNothing);

    await tester.enterText(find.byType(TextField), 'ship the refactor');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(ws.taskCreateRequests, hasLength(1));
    expect(ws.taskCreateRequests.single['nodeId'], 'node-1');
    expect(ws.taskCreateRequests.single['prompt'], 'ship the refactor');
    expect(ws.taskCreateRequests.single['projectPath'], '/repo/mobilepi');
    expect(ws.taskCreateRequests.single['piInstanceId'], 'default-pi');
    expect(ws.taskCreateRequests.single['model'], 'provider/model-a');
    expect(find.byType(TaskDetailScreen), findsOneWidget);
    expect(find.textContaining('ship the refactor'), findsWidgets);
  });
}

class _FakeWebSocketService extends WebSocketService {
  final StreamController<MobilePiMessage> _messages =
      StreamController<MobilePiMessage>.broadcast();
  final StreamController<bool> _connections =
      StreamController<bool>.broadcast();
  final List<Map<String, dynamic>> taskCreateRequests = [];

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
      'agentType': agentType,
      'piInstanceId': piInstanceId,
      'model': model,
      'projectPath': projectPath,
    });
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
            ProtocolPayloadKeys.piModels: [
              {
                'id': 'provider/model-a',
                'provider': 'provider',
                'model': 'model-a',
                'name': 'Model A',
                'isDefault': true,
              },
            ],
            ProtocolPayloadKeys.piInstances: [
              {
                'id': 'default-pi',
                'name': 'Default Pi',
                'isDefault': true,
                'isRunning': true,
              },
            ],
          },
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
