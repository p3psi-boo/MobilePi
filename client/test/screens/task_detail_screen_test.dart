import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mobilepi_client/providers/node_provider.dart';
import 'package:mobilepi_client/screens/task_detail_screen.dart';
import 'package:mobilepi_client/services/log_buffer.dart';
import 'package:mobilepi_client/services/session_cache.dart';
import 'package:mobilepi_client/services/websocket_service.dart';
import 'package:mobilepi_client/theme/app_tokens.dart';
import 'package:mobilepi_client/widgets/pi_markdown.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LogBuffer.instance.clear();
  });

  tearDown(() {
    LogBuffer.instance.clear();
    PiMarkdown.debugClearCache();
  });

  testWidgets('bottom log handle opens an in-context log drawer', (
    tester,
  ) async {
    LogBuffer.instance.addForTesting(
      LogRecord(Level.INFO, 'detail drawer log entry', 'task.detail.test'),
    );

    final ws = _FakeWebSocketService();
    final provider = NodeProvider(
      webSocketService: ws,
      sessionCache: SessionCache.inMemory(),
    );
    final taskId = provider.sendTaskCommand('inspect logs', nodeId: 'node-1');

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

    await tester.tap(find.byTooltip('日志'));
    await tester.pumpAndSettle();

    expect(find.text('日志'), findsOneWidget);
    expect(find.textContaining('detail drawer log entry'), findsOneWidget);
    expect(find.textContaining('task.detail.test'), findsOneWidget);
  });

  testWidgets('left edge swipe returns from task detail', (tester) async {
    final ws = _FakeWebSocketService();
    final provider = NodeProvider(
      webSocketService: ws,
      sessionCache: SessionCache.inMemory(),
    );
    final taskId = provider.sendTaskCommand(
      'edge swipe task',
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
      ),
    );

    await tester.tap(find.text('Open detail'));
    await tester.pumpAndSettle();
    expect(find.text('edge swipe task'), findsWidgets);

    await tester.dragFrom(const Offset(4, 360), const Offset(140, 0));
    await tester.pumpAndSettle();

    expect(find.text('Open detail'), findsOneWidget);
    expect(find.text('edge swipe task'), findsNothing);
  });

  testWidgets('composer avoids double bottom padding while keyboard is open', (
    tester,
  ) async {
    final ws = _FakeWebSocketService();
    final provider = NodeProvider(
      webSocketService: ws,
      sessionCache: SessionCache.inMemory(),
    );
    final taskId = provider.sendTaskCommand(
      'keyboard padding',
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
          home: MediaQuery(
            data: const MediaQueryData(
              padding: EdgeInsets.only(bottom: 34),
              viewInsets: EdgeInsets.only(bottom: 320),
            ),
            child: TaskDetailScreen(taskId: taskId),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final inputBar = tester.widget<Container>(
      find.byKey(const ValueKey('task-detail-input-bar')),
    );
    final padding = inputBar.padding as EdgeInsets;

    expect(padding.bottom, 10);
  });

  testWidgets('bottom composer actions keep mobile touch targets', (
    tester,
  ) async {
    final ws = _FakeWebSocketService();
    final provider = NodeProvider(
      webSocketService: ws,
      sessionCache: SessionCache.inMemory(),
    );
    final taskId = provider.sendTaskCommand(
      'touch target task',
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

    final logHandleSize = tester.getSize(find.byTooltip('日志'));
    final sendButtonSize = tester.getSize(find.byTooltip('发送'));

    expect(logHandleSize.height, greaterThanOrEqualTo(44));
    expect(sendButtonSize.width, greaterThanOrEqualTo(44));
    expect(sendButtonSize.height, greaterThanOrEqualTo(44));
  });

  testWidgets('streaming output uses plain text until the task is final', (
    tester,
  ) async {
    final ws = _FakeWebSocketService();
    final provider = NodeProvider(
      webSocketService: ws,
      sessionCache: SessionCache.inMemory(),
    );
    final taskId = provider.sendTaskCommand(
      'stream markdown cheaply',
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
    PiMarkdown.debugClearCache();

    ws.emitTaskDelta(taskId, seq: 1, delta: 'hello **world**');
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('hello **world**'), findsOneWidget);
    expect(PiMarkdown.debugCacheSize, 0);

    ws.emitTaskCompleted(taskId, seq: 2);
    await tester.pumpAndSettle();

    expect(PiMarkdown.debugCacheSize, 1);
  });

  testWidgets('repeated streaming markdown deltas keep markdown cache cold', (
    tester,
  ) async {
    final ws = _FakeWebSocketService();
    final provider = NodeProvider(
      webSocketService: ws,
      sessionCache: SessionCache.inMemory(),
    );
    final taskId = provider.sendTaskCommand(
      'stream many markdown chunks cheaply',
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
    PiMarkdown.debugClearCache();

    for (var i = 1; i <= 16; i++) {
      ws.emitTaskDelta(taskId, seq: i, delta: 'chunk $i **bold** `code`\n');
      await tester.pump(const Duration(milliseconds: 120));
      expect(PiMarkdown.debugCacheSize, 0);
    }

    expect(
      provider.getTask(taskId)?.streamingText,
      contains('chunk 16 **bold** `code`'),
    );

    ws.emitTaskCompleted(taskId, seq: 17);
    await tester.pumpAndSettle();

    expect(PiMarkdown.debugCacheSize, 1);
  });

  testWidgets(
    'history list disables keep-alives and keeps repaint boundaries',
    (tester) async {
      final ws = _FakeWebSocketService();
      final provider = NodeProvider(
        webSocketService: ws,
        sessionCache: SessionCache.inMemory(),
      );
      final taskId = provider.sendTaskCommand(
        'render history efficiently',
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

      final sliver = tester.widget<SliverList>(find.byType(SliverList).first);
      final delegate = sliver.delegate;

      expect(delegate, isA<SliverChildBuilderDelegate>());
      final builderDelegate = delegate as SliverChildBuilderDelegate;
      expect(builderDelegate.addAutomaticKeepAlives, isFalse);
      expect(builderDelegate.addRepaintBoundaries, isTrue);
    },
  );
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
