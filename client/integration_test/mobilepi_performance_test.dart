import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobilepi_client/providers/node_provider.dart';
import 'package:mobilepi_client/screens/dashboard_screen.dart';
import 'package:mobilepi_client/screens/task_detail_screen.dart';
import 'package:mobilepi_client/services/session_cache.dart';
import 'package:mobilepi_client/services/websocket_service.dart';
import 'package:mobilepi_client/theme/app_tokens.dart';
import 'package:mobilepi_client/widgets/pi_markdown.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const scenario = String.fromEnvironment(
    'MOBILEPI_PROFILE_SCENARIO',
    defaultValue: 'all',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PiMarkdown.debugClearCache();
  });

  if (_runsScenario(scenario, 'streaming_detail')) {
    testWidgets('profile streaming task detail timeline', (tester) async {
      final ws = _FakeWebSocketService();
      final provider = NodeProvider(
        webSocketService: ws,
        sessionCache: SessionCache.inMemory(),
      );
      final taskId = provider.sendTaskCommand(
        'profile streaming detail',
        nodeId: 'node-1',
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
            home: TaskDetailScreen(taskId: taskId),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final liveMarkdownCacheBaseline = PiMarkdown.debugCacheSize;

      await binding.traceAction(() async {
        for (var i = 1; i <= 48; i++) {
          ws.emitTaskDelta(
            taskId,
            seq: i,
            delta: 'chunk $i **bold** `code` line with enough text to wrap\n',
          );
          await tester.pump(const Duration(milliseconds: 90));
        }
      }, reportKey: 'streaming_detail_timeline');

      expect(PiMarkdown.debugCacheSize, liveMarkdownCacheBaseline);

      ws.emitTaskCompleted(taskId, seq: 49);
      await tester.pumpAndSettle();

      expect(PiMarkdown.debugCacheSize, greaterThan(liveMarkdownCacheBaseline));
      provider.dispose();
    });
  }

  if (_runsScenario(scenario, 'dashboard_scroll')) {
    testWidgets('profile dashboard scrolling timeline', (tester) async {
      final ws = _FakeWebSocketService();
      final provider = NodeProvider(
        webSocketService: ws,
        sessionCache: SessionCache.inMemory(),
      );
      for (var i = 0; i < 120; i++) {
        provider.sendTaskCommand(
          'dashboard scroll item ${i.toString().padLeft(3, '0')}',
          nodeId: 'node-1',
          projectId: 'node-1::/profile',
          projectPath: '/profile',
        );
      }

      await tester.pumpWidget(_ProfileHarness(provider: provider));
      await tester.pumpAndSettle();

      final scrollable = find.byType(Scrollable).first;
      await binding.traceAction(() async {
        for (var i = 0; i < 8; i++) {
          await tester.fling(scrollable, const Offset(0, -700), 1200);
          await tester.pumpAndSettle();
        }
        for (var i = 0; i < 8; i++) {
          await tester.fling(scrollable, const Offset(0, 700), 1200);
          await tester.pumpAndSettle();
        }
      }, reportKey: 'dashboard_scroll_timeline');

      provider.dispose();
    });
  }

  if (_runsScenario(scenario, 'session_cache_hydration')) {
    testWidgets('profile session cache hydration timeline', (tester) async {
      final cache = SessionCache.inMemory();
      await cache.saveSnapshots(
        List.generate(120, (index) {
          final taskId = 'cached-profile-$index';
          return SessionSnapshot(
            taskId: taskId,
            nodeId: 'node-1',
            updatedAt: DateTime.utc(2026, 1, 1, 0, index),
            payload: _cachedTaskPayload(taskId: taskId, index: index),
          );
        }),
      );
      final provider = NodeProvider(
        webSocketService: _FakeWebSocketService(),
        sessionCache: cache,
      );

      await binding.traceAction(() async {
        await provider.loadSettings();
        await tester.pumpWidget(_ProfileHarness(provider: provider));
        await tester.pumpAndSettle();
      }, reportKey: 'session_cache_hydration_timeline');

      expect(provider.recentTasks.length, 120);
      provider.dispose();
    });
  }
}

bool _runsScenario(String selected, String scenario) {
  return selected == 'all' || selected == scenario;
}

class _ProfileHarness extends StatelessWidget {
  const _ProfileHarness({required this.provider});

  final NodeProvider provider;

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
        home: const DashboardScreen(),
      ),
    );
  }
}

Map<String, dynamic> _cachedTaskPayload({
  required String taskId,
  required int index,
}) {
  return {
    'id': taskId,
    'nodeId': 'node-1',
    'projectId': 'node-1::/profile',
    'projectPath': '/profile',
    'sessionId': taskId,
    'sessionPath': '/tmp/$taskId.jsonl',
    'agentType': 'pi',
    'title': 'cached profile session ${index.toString().padLeft(3, '0')}',
    'status': index.isEven ? 'completed' : 'history',
    'messages': [
      {
        'role': 'user',
        'text': 'profile prompt $index',
        'sourceIndex': index * 2,
      },
      {
        'role': 'assistant',
        'text': 'profile response $index with **markdown** and `code`',
        'sourceIndex': index * 2 + 1,
        'parts': [
          {
            'type': 'text',
            'text': 'profile response $index with **markdown** and `code`',
          },
        ],
      },
    ],
    'createdAt': DateTime.utc(2026, 1, 1, 0, index).toIso8601String(),
    'isThinking': false,
  };
}

class _FakeWebSocketService extends WebSocketService {
  final StreamController<MobilePiMessage> _messages =
      StreamController<MobilePiMessage>.broadcast();
  final StreamController<bool> _connections =
      StreamController<bool>.broadcast();

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
  }) {}

  void emitTaskDelta(String taskId, {required int seq, required String delta}) {
    _messages.add(
      MobilePiMessage(
        messageId: 'task-delta-$seq',
        from: 'node:node-1',
        to: 'client',
        type: MessageType.event,
        payload: {
          ProtocolPayloadKeys.streamId: 'task:$taskId',
          ProtocolPayloadKeys.seq: seq,
          ProtocolPayloadKeys.eventType: 'task.output.delta',
          ProtocolPayloadKeys.eventPayload: {
            'taskId': taskId,
            'status': 'running',
            'streamingDelta': delta,
          },
          ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:00.000Z',
        },
        timestamp: DateTime.utc(2026, 1, 1),
      ),
    );
  }

  void emitTaskCompleted(String taskId, {required int seq}) {
    _messages.add(
      MobilePiMessage(
        messageId: 'task-completed-$seq',
        from: 'node:node-1',
        to: 'client',
        type: MessageType.event,
        payload: {
          ProtocolPayloadKeys.streamId: 'task:$taskId',
          ProtocolPayloadKeys.seq: seq,
          ProtocolPayloadKeys.eventType: 'task.completed',
          ProtocolPayloadKeys.eventPayload: {
            'taskId': taskId,
            'status': 'completed',
          },
          ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:01.000Z',
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
