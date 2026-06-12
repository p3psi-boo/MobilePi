import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilepi_client/models/node_state.dart';
import 'package:mobilepi_client/providers/node_provider.dart';
import 'package:mobilepi_client/services/session_cache.dart';
import 'package:mobilepi_client/services/websocket_service.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  group('NodeProvider sync', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('syncs Pi state and messages without replay cursors', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);

      emitNodeSummary(ws, 'sync-1', {
        ProtocolPayloadKeys.nodeId: 'node-1',
        ProtocolPayloadKeys.hostname: 'macbook',
        ProtocolPayloadKeys.platform: 'macos',
        ProtocolPayloadKeys.agents: ['pi'],
        ProtocolPayloadKeys.piState: {'sessionId': 'pi-session-1'},
        ProtocolPayloadKeys.piMessages: [
          {'role': 'user', 'text': 'hello'},
        ],
      });

      await Future<void>.delayed(Duration.zero);

      expect(provider.nodes.single.nodeId, equals('node-1'));
      expect(
        provider.nodes.single.piState?['sessionId'],
        equals('pi-session-1'),
      );
      expect(provider.nodes.single.piMessages.single['text'], equals('hello'));

      ws.emitConnection(true);
      await Future<void>.delayed(Duration.zero);
      provider.refresh();
      await Future<void>.delayed(Duration.zero);

      expect(ws.forceReconnectCount, 1);
      expect(ws.helloPayloads, hasLength(2));
      expect(ws.resumePayloads.map((p) => p['nodeId']), ['node-1', 'node-1']);

      provider.dispose();
    });

    test(
      'maps Pi session index entries into recent tasks with node context',
      () async {
        final ws = FakeWebSocketService();
        final provider = NodeProvider(webSocketService: ws);

        emitNodeSummary(ws, 'sync-sessions', {
          ProtocolPayloadKeys.nodeId: 'node-1',
          ProtocolPayloadKeys.hostname: 'pi-node',
          ProtocolPayloadKeys.platform: 'linux',
          ProtocolPayloadKeys.agents: ['pi'],
          ProtocolPayloadKeys.piSessions: [
            {
              'path': '/Users/bubu/.pi/agent/sessions/s.jsonl',
              'id': 'pi-session-1',
              'cwd': '/Users/bubu/remote-agent',
              'name': '检查浏览器 e2e 问题',
              'created': '2026-01-01T00:00:00.000Z',
              'modified': '2026-01-02T00:01:00.000Z',
              'messageCount': 4,
              'firstMessage': 'fallback title',
              'messages': [
                {
                  'role': 'user',
                  'text': '检查浏览器 e2e 问题',
                  'timestamp': '2026-01-02T00:00:00.000Z',
                },
                {
                  'role': 'assistant',
                  'text': '浏览器 e2e 正常',
                  'timestamp': '2026-01-02T00:01:00.000Z',
                },
              ],
            },
          ],
        });

        await Future<void>.delayed(Duration.zero);

        expect(provider.nodes.single.piSessions.single.id, 'pi-session-1');
        expect(provider.recentTasks, hasLength(1));
        expect(provider.recentTasks.single.nodeId, 'node-1');
        expect(
          provider.recentTasks.single.projectPath,
          '/Users/bubu/remote-agent',
        );
        expect(provider.recentTasks.single.sessionId, 'pi-session-1');
        expect(provider.recentTasks.single.title, '检查浏览器 e2e 问题');
        expect(provider.recentTasks.single.status, 'history');
        expect(provider.recentTasks.single.streamingText, isNull);
        expect(provider.recentTasks.single.messages, hasLength(2));

        final project = provider
            .projectsForNode('node-1')
            .singleWhere(
              (project) => project.path == '/Users/bubu/remote-agent',
            );
        final sessions = provider.sessionsForProject('node-1', project.id);
        expect(sessions.single.id, 'pi-session-1');
        expect(sessions.single.task, isNotNull);

        provider.dispose();
      },
    );

    test(
      'appends streaming deltas without replacing accumulated output',
      () async {
        final ws = FakeWebSocketService();
        final provider = NodeProvider(webSocketService: ws);

        emitTaskDelta(
          ws,
          nodeId: 'node-1',
          taskId: 'task-1',
          seq: 1,
          delta: 'hello',
        );
        await Future<void>.delayed(Duration.zero);

        emitTaskDelta(
          ws,
          nodeId: 'node-1',
          taskId: 'task-1',
          seq: 2,
          delta: ' world',
        );

        await Future<void>.delayed(const Duration(milliseconds: 120));

        expect(
          provider.getTask('task-1')?.streamingText,
          equals('hello world'),
        );

        provider.dispose();
      },
    );

    test('preserves streaming output beyond the render window', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);
      final first = 'a' * 16000;
      final second = 'b' * 16000;

      emitTaskDelta(
        ws,
        nodeId: 'node-1',
        taskId: 'task-long',
        seq: 1,
        delta: first,
      );
      emitTaskDelta(
        ws,
        nodeId: 'node-1',
        taskId: 'task-long',
        seq: 2,
        delta: second,
      );

      await Future<void>.delayed(const Duration(milliseconds: 120));

      final task = provider.getTask('task-long');
      expect(task?.streamingText, '$first$second');
      expect(task?.streamingText?.length, 32000);
      expect(task?.streamingParts.single.text, '$first$second');

      provider.dispose();
    });

    test('coalesces streaming task listenable notifications', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);

      emitNodeSummary(ws, 'sync-node-fixed-cadence', {
        ProtocolPayloadKeys.nodeId: 'node-1',
        ProtocolPayloadKeys.hostname: 'macbook',
        ProtocolPayloadKeys.platform: 'macos',
        ProtocolPayloadKeys.agents: ['pi'],
      });
      await Future<void>.delayed(Duration.zero);

      provider.sendTaskCommand('initial prompt', nodeId: 'node-1');
      final taskId = ws.taskCreateRequests.single['taskId'] as String;
      final taskListenable = provider.taskListenable(taskId);
      var updateCount = 0;
      taskListenable.addListener(() {
        updateCount++;
      });

      emitTaskDelta(ws, nodeId: 'node-1', taskId: taskId, seq: 1, delta: 'a');
      emitTaskDelta(ws, nodeId: 'node-1', taskId: taskId, seq: 2, delta: 'b');
      await Future<void>.delayed(Duration.zero);
      expect(updateCount, 0);
      expect(provider.getTask(taskId)?.streamingText, 'ab');

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(updateCount, 1);
      expect(taskListenable.value?.streamingText, 'ab');

      provider.dispose();
    });

    test(
      'streaming incremental events do not notify global listeners',
      () async {
        final ws = FakeWebSocketService();
        final provider = NodeProvider(webSocketService: ws);

        emitNodeSummary(ws, 'sync-node-local-only-streaming', {
          ProtocolPayloadKeys.nodeId: 'node-1',
          ProtocolPayloadKeys.hostname: 'macbook',
          ProtocolPayloadKeys.platform: 'macos',
          ProtocolPayloadKeys.agents: ['pi'],
        });
        await Future<void>.delayed(Duration.zero);

        provider.sendTaskCommand('initial prompt', nodeId: 'node-1');
        final taskId = ws.taskCreateRequests.single['taskId'] as String;
        var globalUpdateCount = 0;
        provider.addListener(() {
          globalUpdateCount++;
        });

        emitTaskDelta(ws, nodeId: 'node-1', taskId: taskId, seq: 1, delta: 'a');
        emitToolCall(
          ws,
          nodeId: 'node-1',
          taskId: taskId,
          seq: 2,
          name: 'Read',
        );
        emitToolResult(
          ws,
          nodeId: 'node-1',
          taskId: taskId,
          seq: 3,
          name: 'Read',
        );
        emitThinkingBoundary(
          ws,
          nodeId: 'node-1',
          taskId: taskId,
          seq: 4,
          boundary: 'start',
        );
        emitTaskProgress(
          ws,
          nodeId: 'node-1',
          taskId: taskId,
          seq: 5,
          percent: 42,
        );

        await Future<void>.delayed(const Duration(milliseconds: 120));

        expect(globalUpdateCount, 0);
        expect(provider.getTask(taskId)?.streamingText, 'a');
        expect(provider.getTask(taskId)?.streamingParts.length, 3);
        expect(provider.getTask(taskId)?.progressPercent, 42);

        provider.dispose();
      },
    );

    test('task listenable updates only for its task', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);
      final taskListenable = provider.taskListenable('task-1');
      var updateCount = 0;
      taskListenable.addListener(() {
        updateCount++;
      });

      emitTaskDelta(
        ws,
        nodeId: 'node-1',
        taskId: 'task-1',
        seq: 1,
        delta: 'hello',
      );
      await Future<void>.delayed(Duration.zero);

      expect(updateCount, 1);
      expect(taskListenable.value?.streamingText, 'hello');

      emitTaskDelta(
        ws,
        nodeId: 'node-1',
        taskId: 'task-2',
        seq: 1,
        delta: 'unrelated',
      );
      await Future<void>.delayed(Duration.zero);

      expect(updateCount, 1);
      expect(taskListenable.value?.streamingText, 'hello');

      provider.removeTask('task-1');

      expect(updateCount, 2);
      expect(taskListenable.value, isNull);

      provider.dispose();
    });

    test('recent tasks listenable ignores streaming-only deltas', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);
      var recentUpdateCount = 0;
      provider.recentTasksListenable.addListener(() {
        recentUpdateCount++;
      });

      emitTaskDelta(
        ws,
        nodeId: 'node-1',
        taskId: 'task-1',
        seq: 1,
        delta: 'hello',
      );
      await Future<void>.delayed(Duration.zero);

      expect(recentUpdateCount, 1);
      expect(provider.recentTasks.single.id, 'task-1');

      emitTaskDelta(
        ws,
        nodeId: 'node-1',
        taskId: 'task-1',
        seq: 2,
        delta: ' world',
      );
      await Future<void>.delayed(Duration.zero);

      expect(recentUpdateCount, 1);
      expect(provider.getTask('task-1')?.streamingText, 'hello world');

      emitTaskProgress(
        ws,
        nodeId: 'node-1',
        taskId: 'task-1',
        seq: 3,
        percent: 42,
      );
      await Future<void>.delayed(Duration.zero);

      expect(recentUpdateCount, 2);
      expect(provider.recentTasks.single.progressPercent, 42);

      provider.dispose();
    });

    test('protocol events advance cursor and ignore duplicate seq', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);

      emitNodeSummary(ws, 'sync-node-event', {
        ProtocolPayloadKeys.nodeId: 'node-1',
        ProtocolPayloadKeys.hostname: 'macbook',
        ProtocolPayloadKeys.platform: 'macos',
        ProtocolPayloadKeys.agents: ['pi'],
      });
      await Future<void>.delayed(Duration.zero);

      void emitEvent(int seq, String delta) {
        ws.emitMessage(
          MobilePiMessage(
            messageId: 'event-$seq-$delta',
            from: 'node:node-1',
            to: 'client',
            type: MessageType.event,
            payload: {
              ProtocolPayloadKeys.streamId: 'task:task-1',
              ProtocolPayloadKeys.seq: seq,
              ProtocolPayloadKeys.eventType: 'task.output.delta',
              'taskId': 'task-1',
              ProtocolPayloadKeys.eventPayload: {
                'taskId': 'task-1',
                'status': 'running',
                'streamingDelta': delta,
              },
              ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:00.000Z',
            },
            timestamp: DateTime.utc(2026, 1, 1),
          ),
        );
      }

      emitEvent(1, 'hello');
      emitEvent(1, ' duplicate');
      emitEvent(2, ' world');

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(provider.getTask('task-1')?.streamingText, equals('hello world'));

      provider.dispose();
    });

    test(
      'resume applies truncated stream snapshot before replay events',
      () async {
        final ws = FakeWebSocketService();
        final provider = NodeProvider(webSocketService: ws);

        emitNodeSummary(ws, 'sync-node-truncated', {
          ProtocolPayloadKeys.nodeId: 'node-1',
          ProtocolPayloadKeys.hostname: 'macbook',
          ProtocolPayloadKeys.platform: 'macos',
          ProtocolPayloadKeys.agents: ['pi'],
        });
        await Future<void>.delayed(Duration.zero);

        ws.emitMessage(
          MobilePiMessage(
            messageId: 'resume-truncated',
            from: 'node:node-1',
            to: 'client',
            type: MessageType.response,
            payload: {
              ProtocolPayloadKeys.responseTo: 'resume-truncated',
              ProtocolPayloadKeys.truncatedStreams: [
                {
                  ProtocolPayloadKeys.streamId: 'task:task-1',
                  'requestedSeq': 0,
                  'latestSeq': 5,
                  'snapshot': {
                    ProtocolPayloadKeys.streamId: 'task:task-1',
                    ProtocolPayloadKeys.seq: 5,
                    ProtocolPayloadKeys.eventType: 'task.snapshot',
                    ProtocolPayloadKeys.eventPayload: {
                      'taskId': 'task-1',
                      'status': 'completed',
                      ProtocolPayloadKeys.title: 'Recovered task',
                      ProtocolPayloadKeys.projectPath: '/repo',
                    },
                    ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:05.000Z',
                  },
                },
              ],
              ProtocolPayloadKeys.events: [
                {
                  ProtocolPayloadKeys.streamId: 'task:task-1',
                  ProtocolPayloadKeys.seq: 3,
                  ProtocolPayloadKeys.eventType: 'task.output.delta',
                  ProtocolPayloadKeys.eventPayload: {
                    'taskId': 'task-1',
                    'status': 'running',
                    'streamingDelta': 'stale',
                  },
                  ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:03.000Z',
                },
              ],
            },
            timestamp: DateTime.utc(2026, 1, 1),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final task = provider.getTask('task-1');
        expect(task?.status, 'completed');
        expect(task?.title, 'Recovered task');
        expect(task?.projectPath, '/repo');
        expect(task?.streamingText, isNull);

        ws.emitConnection(true);
        await Future<void>.delayed(Duration.zero);

        expect(
          ws.resumePayloads.last['cursors'],
          containsPair('task:task-1', 5),
        );

        provider.dispose();
      },
    );

    test('resume hasMore requests next page with advanced cursors', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);

      ws.emitMessage(
        MobilePiMessage(
          messageId: 'resume-page-1',
          from: 'node:node-1',
          to: 'client',
          type: MessageType.response,
          payload: {
            ProtocolPayloadKeys.responseTo: 'resume-page-1',
            ProtocolPayloadKeys.hasMore: true,
            ProtocolPayloadKeys.events: [
              {
                ProtocolPayloadKeys.streamId: 'task:task-1',
                ProtocolPayloadKeys.seq: 1,
                ProtocolPayloadKeys.eventType: 'task.output.delta',
                ProtocolPayloadKeys.eventPayload: {
                  'taskId': 'task-1',
                  'status': 'running',
                  'streamingDelta': 'hello',
                },
                ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:01.000Z',
              },
              {
                ProtocolPayloadKeys.streamId: 'task:task-1',
                ProtocolPayloadKeys.seq: 2,
                ProtocolPayloadKeys.eventType: 'task.output.delta',
                ProtocolPayloadKeys.eventPayload: {
                  'taskId': 'task-1',
                  'status': 'running',
                  'streamingDelta': ' world',
                },
                ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:02.000Z',
              },
            ],
          },
          timestamp: DateTime.utc(2026, 1, 1),
        ),
      );

      await Future<void>.delayed(Duration.zero);

      expect(provider.getTask('task-1')?.streamingText, 'hello world');
      expect(ws.resumePayloads, hasLength(1));
      expect(ws.resumePayloads.single['nodeId'], 'node-1');
      expect(
        ws.resumePayloads.single['cursors'],
        containsPair('task:task-1', 2),
      );

      provider.dispose();
    });

    test(
      'builds streaming parts from structured thinking boundaries',
      () async {
        final ws = FakeWebSocketService();
        final provider = NodeProvider(webSocketService: ws);

        emitThinkingBoundary(
          ws,
          nodeId: 'node-1',
          taskId: 'task-1',
          seq: 1,
          boundary: 'start',
        );
        emitTaskDelta(
          ws,
          nodeId: 'node-1',
          taskId: 'task-1',
          seq: 2,
          delta: 'reasoning',
        );
        emitThinkingBoundary(
          ws,
          nodeId: 'node-1',
          taskId: 'task-1',
          seq: 3,
          boundary: 'end',
        );
        emitTaskDelta(
          ws,
          nodeId: 'node-1',
          taskId: 'task-1',
          seq: 4,
          delta: '\nfinal answer',
        );

        await Future<void>.delayed(const Duration(milliseconds: 120));

        final task = provider.getTask('task-1');
        expect(task?.streamingText, equals('reasoning\nfinal answer'));
        expect(task?.isThinking, isFalse);
        expect(task?.streamingParts, hasLength(2));
        expect(task?.streamingParts[0].type, MessagePartType.thinking);
        expect(task?.streamingParts[0].text, 'reasoning');
        expect(task?.streamingParts[1].type, MessagePartType.text);
        expect(task?.streamingParts[1].text, '\nfinal answer');

        provider.dispose();
      },
    );

    test(
      'coalesces running tool and thinking events into one notify',
      () async {
        final ws = FakeWebSocketService();
        final provider = NodeProvider(webSocketService: ws);
        var notifyCount = 0;
        var taskNotifyCount = 0;
        provider.addListener(() {
          notifyCount++;
        });

        emitTaskDelta(
          ws,
          nodeId: 'node-1',
          taskId: 'task-1',
          seq: 1,
          delta: 'hello',
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(notifyCount, 1);
        final taskListenable = provider.taskListenable('task-1');
        taskListenable.addListener(() {
          taskNotifyCount++;
        });

        emitToolCall(
          ws,
          nodeId: 'node-1',
          taskId: 'task-1',
          seq: 2,
          name: 'Read',
        );
        emitToolResult(
          ws,
          nodeId: 'node-1',
          taskId: 'task-1',
          seq: 3,
          name: 'Read',
        );
        emitThinkingBoundary(
          ws,
          nodeId: 'node-1',
          taskId: 'task-1',
          seq: 4,
          boundary: 'start',
        );

        await Future<void>.delayed(Duration.zero);
        expect(notifyCount, 1);
        expect(taskNotifyCount, 0);

        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(notifyCount, 1);
        expect(taskNotifyCount, 1);
        final task = provider.getTask('task-1');
        expect(task?.isThinking, isTrue);
        expect(task?.streamingParts, hasLength(3));
        expect(task?.streamingParts[0].type, MessagePartType.text);
        expect(task?.streamingParts[0].text, 'hello');
        expect(task?.streamingParts[1].type, MessagePartType.toolCall);
        expect(task?.streamingParts[1].name, 'Read');
        expect(task?.streamingParts[1].id, 'call-2');
        expect(task?.streamingParts[2].type, MessagePartType.toolResult);
        expect(task?.streamingParts[2].name, 'Read');
        expect(task?.streamingParts[2].id, 'call-2');
        expect(task?.streamingParts[2].text, 'ok');

        provider.dispose();
      },
    );

    test('connects to the configured Hub URL without daemon editing', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);

      await provider.loadSettings();
      provider.connect();

      expect(provider.hubUrl, equals('ws://localhost:8080/ws'));
      expect(provider.tenantKey, equals('tenant-a'));
      expect(ws.hubUrl, equals('ws://localhost:8080/ws'));
      expect(ws.connectCount, equals(1));

      provider.dispose();
    });

    test(
      'hydrates recent tasks from session cache before network sync',
      () async {
        final cache = SessionCache.inMemory();
        await cache.saveSnapshots([
          SessionSnapshot(
            taskId: 'cached-task',
            nodeId: 'node-1',
            updatedAt: DateTime.parse('2026-01-02T00:00:00Z'),
            payload: {
              'id': 'cached-task',
              'nodeId': 'node-1',
              'projectId': 'node-1::/repo',
              'projectPath': '/repo',
              'sessionId': 'session-1',
              'sessionPath': '/tmp/session.jsonl',
              'title': 'cached title',
              'status': 'history',
              'createdAt': '2026-01-02T00:00:00.000Z',
              'messages': [
                {
                  'role': 'user',
                  'text': 'cached prompt',
                  'timestamp': '2026-01-02T00:00:00.000Z',
                },
                {
                  'role': 'assistant',
                  'text': '',
                  'parts': [
                    {'type': 'text', 'text': 'cached answer'},
                  ],
                },
              ],
            },
          ),
        ]);
        final ws = FakeWebSocketService();
        final provider = NodeProvider(
          webSocketService: ws,
          sessionCache: cache,
        );

        await provider.loadSettings();

        expect(provider.recentTasks, hasLength(1));
        expect(provider.recentTasks.single.id, 'cached-task');
        expect(provider.recentTasks.single.displayTitle, 'cached prompt');
        expect(
          provider.recentTasks.single.messages.last.structuredPreviewText,
          'cached answer',
        );

        provider.dispose();
      },
    );

    test('persists optimistic task snapshots into session cache', () async {
      final cache = SessionCache.inMemory();
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws, sessionCache: cache);

      emitNodeSummary(ws, 'sync-node-cache-save', {
        ProtocolPayloadKeys.nodeId: 'node-1',
        ProtocolPayloadKeys.hostname: 'macbook',
        ProtocolPayloadKeys.platform: 'macos',
        ProtocolPayloadKeys.agents: ['pi'],
      });
      await Future<void>.delayed(Duration.zero);

      provider.sendTaskCommand(
        'cache this prompt',
        nodeId: 'node-1',
        projectId: 'node-1::/repo',
        projectPath: '/repo',
      );

      await Future<void>.delayed(const Duration(milliseconds: 650));

      final snapshots = await cache.loadRecent();
      expect(snapshots, hasLength(1));
      final payload = snapshots.single.payload;
      expect(payload['title'], 'cache this prompt');
      expect(payload['projectPath'], '/repo');
      expect(payload['status'], 'running');
      final messages = payload['messages'] as List<dynamic>;
      expect(messages.single['role'], 'user');
      expect(messages.single['text'], 'cache this prompt');

      provider.dispose();
    });

    test('does not connect until tenant key is configured', () async {
      final ws = FakeWebSocketService(initialTenantKey: '');
      final provider = NodeProvider(webSocketService: ws);

      provider.connect();

      expect(provider.hasTenantKey, isFalse);
      expect(ws.connectCount, equals(0));

      await provider.setHubConnection(
        url: 'ws://localhost:8080/ws',
        tenantKey: 'tenant-a',
      );

      expect(provider.hasTenantKey, isTrue);
      expect(provider.tenantKey, 'tenant-a');
      expect(ws.connectCount, equals(1));

      provider.dispose();
    });

    test('foreground resume forces reconnect and resyncs cursors', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);

      emitNodeSummary(ws, 'sync-node-resume', {
        ProtocolPayloadKeys.nodeId: 'node-1',
        ProtocolPayloadKeys.hostname: 'macbook',
        ProtocolPayloadKeys.platform: 'macos',
        ProtocolPayloadKeys.agents: ['pi'],
      });
      await Future<void>.delayed(Duration.zero);

      emitTaskDelta(
        ws,
        nodeId: 'node-1',
        taskId: 'task-1',
        seq: 1,
        delta: 'hello',
      );
      await Future<void>.delayed(Duration.zero);

      ws.helloPayloads.clear();
      ws.resumePayloads.clear();

      provider.onAppResumed();
      await Future<void>.delayed(Duration.zero);

      expect(ws.forceReconnectCount, 1);
      expect(ws.helloPayloads, hasLength(1));
      expect(ws.resumePayloads, hasLength(1));
      expect(ws.resumePayloads.single['nodeId'], 'node-1');
      expect(
        ws.resumePayloads.single['cursors'],
        containsPair('task:task-1', 1),
      );

      provider.dispose();
    });

    test(
      'derives Node project and active session hierarchy from Pi state',
      () async {
        final ws = FakeWebSocketService();
        final provider = NodeProvider(webSocketService: ws);

        emitNodeSummary(ws, 'sync-project', {
          ProtocolPayloadKeys.nodeId: 'node-1',
          ProtocolPayloadKeys.hostname: 'macbook',
          ProtocolPayloadKeys.platform: 'macos',
          ProtocolPayloadKeys.agents: ['pi'],
          ProtocolPayloadKeys.piState: {
            'sessionId': 'session-1',
            'cwd': '/Users/bubu/remote-agent',
          },
        });
        await Future<void>.delayed(Duration.zero);

        final projects = provider.projectsForNode('node-1');
        expect(projects, hasLength(1));
        expect(projects.single.name, equals('remote-agent'));
        expect(projects.single.path, equals('/Users/bubu/remote-agent'));
        expect(projects.single.sessionCount, equals(1));

        final sessions = provider.sessionsForProject(
          'node-1',
          projects.single.id,
        );
        expect(sessions.single.id, equals('session-1'));
        expect(sessions.single.status, equals('running'));

        provider.dispose();
      },
    );

    test('new task session is associated with selected project', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);

      emitNodeSummary(ws, 'sync-node', {
        ProtocolPayloadKeys.nodeId: 'node-1',
        ProtocolPayloadKeys.hostname: 'macbook',
        ProtocolPayloadKeys.platform: 'macos',
        ProtocolPayloadKeys.agents: ['pi'],
      });
      await Future<void>.delayed(Duration.zero);

      provider.sendTaskCommand(
        'run tests',
        nodeId: 'node-1',
        projectId: 'node-1::/tmp/project-a',
        projectPath: '/tmp/project-a',
      );

      final sessions = provider.sessionsForProject(
        'node-1',
        'node-1::/tmp/project-a',
      );
      expect(sessions, hasLength(1));
      expect(sessions.single.title, equals('run tests'));
      expect(
        sessions.single.id,
        equals(ws.taskCreateRequests.single['taskId']),
      );
      expect(ws.taskCreateRequests.single['prompt'], equals('run tests'));

      provider.dispose();
    });

    test('follow-up appends user message before daemon response', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);

      emitNodeSummary(ws, 'sync-node-followup', {
        ProtocolPayloadKeys.nodeId: 'node-1',
        ProtocolPayloadKeys.hostname: 'macbook',
        ProtocolPayloadKeys.platform: 'macos',
        ProtocolPayloadKeys.agents: ['pi'],
      });
      await Future<void>.delayed(Duration.zero);

      provider.sendTaskCommand('initial prompt', nodeId: 'node-1');
      final taskId = ws.taskCreateRequests.single['taskId'] as String;

      provider.sendFollowUp(taskId, 'continue with tests');

      final task = provider.getTask(taskId);
      expect(task?.messages.map((message) => message.text), [
        'initial prompt',
        'continue with tests',
      ]);
      expect(ws.followUpRequests.single['taskId'], equals(taskId));
      expect(
        ws.followUpRequests.single['message'],
        equals('continue with tests'),
      );

      provider.dispose();
    });

    test('steer appends user message before daemon response', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);

      emitNodeSummary(ws, 'sync-node-steer', {
        ProtocolPayloadKeys.nodeId: 'node-1',
        ProtocolPayloadKeys.hostname: 'macbook',
        ProtocolPayloadKeys.platform: 'macos',
        ProtocolPayloadKeys.agents: ['pi'],
      });
      await Future<void>.delayed(Duration.zero);

      provider.sendTaskCommand('initial prompt', nodeId: 'node-1');
      final taskId = ws.taskCreateRequests.single['taskId'] as String;

      provider.sendSteer(taskId, 'change direction');

      final task = provider.getTask(taskId);
      expect(task?.messages.map((message) => message.text), [
        'initial prompt',
        'change direction',
      ]);
      expect(ws.steerRequests.single['taskId'], equals(taskId));
      expect(ws.steerRequests.single['message'], equals('change direction'));

      provider.dispose();
    });

    test('composer message steers running task automatically', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);

      emitNodeSummary(ws, 'sync-node-composer-steer', {
        ProtocolPayloadKeys.nodeId: 'node-1',
        ProtocolPayloadKeys.hostname: 'macbook',
        ProtocolPayloadKeys.platform: 'macos',
        ProtocolPayloadKeys.agents: ['pi'],
      });
      await Future<void>.delayed(Duration.zero);

      provider.sendTaskCommand('initial prompt', nodeId: 'node-1');
      final taskId = ws.taskCreateRequests.single['taskId'] as String;

      provider.sendComposerMessage(taskId, 'change direction');

      expect(ws.steerRequests.single['taskId'], equals(taskId));
      expect(ws.steerRequests.single['message'], equals('change direction'));
      expect(ws.followUpRequests, isEmpty);
      expect(
        provider.getTask(taskId)?.messages.map((message) => message.text),
        ['initial prompt', 'change direction'],
      );

      provider.dispose();
    });

    test(
      'composer message steers waiting decision task automatically',
      () async {
        final ws = FakeWebSocketService();
        final provider = NodeProvider(webSocketService: ws);

        emitNodeSummary(ws, 'sync-node-composer-waiting', {
          ProtocolPayloadKeys.nodeId: 'node-1',
          ProtocolPayloadKeys.hostname: 'macbook',
          ProtocolPayloadKeys.platform: 'macos',
          ProtocolPayloadKeys.agents: ['pi'],
        });
        await Future<void>.delayed(Duration.zero);

        provider.sendTaskCommand('initial prompt', nodeId: 'node-1');
        final taskId = ws.taskCreateRequests.single['taskId'] as String;
        ws.emitMessage(
          MobilePiMessage(
            messageId: 'waiting-event',
            from: 'node:node-1',
            to: 'client',
            type: MessageType.event,
            payload: {
              ProtocolPayloadKeys.streamId: 'task:$taskId',
              ProtocolPayloadKeys.seq: 1,
              ProtocolPayloadKeys.eventType: 'task.status',
              ProtocolPayloadKeys.eventPayload: {
                'taskId': taskId,
                'status': 'waitingDecision',
              },
              ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:00.000Z',
            },
            timestamp: DateTime.utc(2026, 1, 1),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        provider.sendComposerMessage(taskId, 'try another approach');

        expect(ws.steerRequests.single['taskId'], equals(taskId));
        expect(
          ws.steerRequests.single['message'],
          equals('try another approach'),
        );
        expect(ws.followUpRequests, isEmpty);
        expect(provider.getTask(taskId)?.status, equals('waitingDecision'));

        provider.dispose();
      },
    );

    test(
      'composer message follows up non-running session automatically',
      () async {
        final ws = FakeWebSocketService();
        final provider = NodeProvider(webSocketService: ws);

        emitNodeSummary(ws, 'sync-node-composer-followup', {
          ProtocolPayloadKeys.nodeId: 'node-1',
          ProtocolPayloadKeys.hostname: 'macbook',
          ProtocolPayloadKeys.platform: 'macos',
          ProtocolPayloadKeys.agents: ['pi'],
          ProtocolPayloadKeys.piSessions: [
            {
              'path': '/tmp/session.jsonl',
              'id': 'session-1',
              'cwd': '/repo',
              'name': 'finished task',
              'modified': '2026-01-02T00:00:00.000Z',
              'messages': [
                {'role': 'user', 'text': 'initial prompt'},
              ],
            },
          ],
        });
        await Future<void>.delayed(Duration.zero);
        final taskId = provider.recentTasks.single.id;

        provider.sendComposerMessage(taskId, 'continue with tests');

        expect(ws.followUpRequests.single['taskId'], equals(taskId));
        expect(
          ws.followUpRequests.single['message'],
          equals('continue with tests'),
        );
        expect(ws.steerRequests, isEmpty);
        expect(
          provider.getTask(taskId)?.messages.map((message) => message.text),
          ['initial prompt', 'continue with tests'],
        );

        provider.dispose();
      },
    );

    test('session pagination deduplicates by sourceIndex', () async {
      final ws = FakeWebSocketService();
      final provider = NodeProvider(webSocketService: ws);

      emitNodeSummary(ws, 'sync-node-source-index', {
        ProtocolPayloadKeys.nodeId: 'node-1',
        ProtocolPayloadKeys.hostname: 'macbook',
        ProtocolPayloadKeys.platform: 'macos',
        ProtocolPayloadKeys.agents: ['pi'],
        ProtocolPayloadKeys.piSessions: [
          {
            'path': '/tmp/session-source-index.jsonl',
            'id': 'session-source-index',
            'cwd': '/repo',
            'name': 'source index session',
            'modified': '2026-01-02T00:00:00.000Z',
            'messageCount': 11,
            'messages': [
              {
                'role': 'assistant',
                'text': '',
                'sourceIndex': 10,
                'parts': [
                  {'type': 'toolCall', 'name': 'Read', 'id': 'call-10'},
                ],
              },
            ],
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);
      final taskId = provider.recentTasks.single.id;

      ws.emitMessage(
        MobilePiMessage(
          messageId: 'messages-source-index',
          from: 'node:node-1',
          to: 'client',
          type: MessageType.response,
          payload: {
            ProtocolPayloadKeys.responseTo: 'messages-source-index',
            'sessionPath': '/tmp/session-source-index.jsonl',
            'totalCount': 11,
            'nextBeforeIndex': 9,
            'messages': [
              {'role': 'user', 'text': 'older prompt', 'sourceIndex': 9},
              {
                'role': 'assistant',
                'text': '',
                'sourceIndex': 10,
                'parts': [
                  {'type': 'toolCall', 'name': 'Read', 'id': 'call-10'},
                ],
              },
            ],
          },
          timestamp: DateTime.utc(2026, 1, 1),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final messages = provider.getTask(taskId)?.messages;
      expect(messages, hasLength(2));
      expect(messages?.map((message) => message.sourceIndex), [9, 10]);
      expect(messages?.first.text, 'older prompt');

      provider.dispose();
    });
  });

  group('WebSocketService Hub URL normalization', () {
    test('adds ws scheme and default /ws path', () {
      expect(
        WebSocketService.normalizeHubUrl('hub.local:8080'),
        equals('ws://hub.local:8080/ws'),
      );
    });

    test('maps http schemes to websocket schemes', () {
      expect(
        WebSocketService.normalizeHubUrl('http://hub.local:8080'),
        equals('ws://hub.local:8080/ws'),
      );
      expect(
        WebSocketService.normalizeHubUrl('https://hub.local:9443/api'),
        equals('wss://hub.local:9443/api'),
      );
    });
  });

  group('WebSocketService tenant key normalization', () {
    test('trims tenant key', () {
      expect(WebSocketService.normalizeTenantKey('  tenant-a  '), 'tenant-a');
    });
  });
}

void emitNodeSummary(
  FakeWebSocketService ws,
  String messageId,
  Map<String, dynamic> summary,
) {
  ws.emitMessage(
    MobilePiMessage(
      messageId: messageId,
      from: 'hub',
      to: 'client',
      type: MessageType.response,
      payload: {
        ProtocolPayloadKeys.responseTo: messageId,
        ProtocolPayloadKeys.nodeSummary: summary,
      },
      timestamp: DateTime.utc(2026, 1, 1),
    ),
  );
}

void emitTaskDelta(
  FakeWebSocketService ws, {
  required String nodeId,
  required String taskId,
  required int seq,
  required String delta,
}) {
  ws.emitMessage(
    MobilePiMessage(
      messageId: 'event-$seq-$delta',
      from: 'node:$nodeId',
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

void emitTaskProgress(
  FakeWebSocketService ws, {
  required String nodeId,
  required String taskId,
  required int seq,
  required int percent,
}) {
  ws.emitMessage(
    MobilePiMessage(
      messageId: 'event-$seq-progress',
      from: 'node:$nodeId',
      to: 'client',
      type: MessageType.event,
      payload: {
        ProtocolPayloadKeys.streamId: 'task:$taskId',
        ProtocolPayloadKeys.seq: seq,
        ProtocolPayloadKeys.eventType: 'task.progress',
        ProtocolPayloadKeys.eventPayload: {
          'taskId': taskId,
          'status': 'running',
          'percent': percent,
        },
        ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:00.000Z',
      },
      timestamp: DateTime.utc(2026, 1, 1),
    ),
  );
}

void emitThinkingBoundary(
  FakeWebSocketService ws, {
  required String nodeId,
  required String taskId,
  required int seq,
  required String boundary,
}) {
  ws.emitMessage(
    MobilePiMessage(
      messageId: 'event-$seq-thinking-$boundary',
      from: 'node:$nodeId',
      to: 'client',
      type: MessageType.event,
      payload: {
        ProtocolPayloadKeys.streamId: 'task:$taskId',
        ProtocolPayloadKeys.seq: seq,
        ProtocolPayloadKeys.eventType: 'task.output.delta',
        ProtocolPayloadKeys.eventPayload: {
          'taskId': taskId,
          'status': 'running',
          ProtocolPayloadKeys.thinking: boundary,
        },
        ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:00.000Z',
      },
      timestamp: DateTime.utc(2026, 1, 1),
    ),
  );
}

void emitToolCall(
  FakeWebSocketService ws, {
  required String nodeId,
  required String taskId,
  required int seq,
  required String name,
}) {
  ws.emitMessage(
    MobilePiMessage(
      messageId: 'event-$seq-tool-call',
      from: 'node:$nodeId',
      to: 'client',
      type: MessageType.event,
      payload: {
        ProtocolPayloadKeys.streamId: 'task:$taskId',
        ProtocolPayloadKeys.seq: seq,
        ProtocolPayloadKeys.eventType: 'task.output.delta',
        ProtocolPayloadKeys.eventPayload: {
          'taskId': taskId,
          'status': 'running',
          ProtocolPayloadKeys.toolCall: {'id': 'call-$seq', 'name': name},
        },
        ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:00.000Z',
      },
      timestamp: DateTime.utc(2026, 1, 1),
    ),
  );
}

void emitToolResult(
  FakeWebSocketService ws, {
  required String nodeId,
  required String taskId,
  required int seq,
  required String name,
}) {
  ws.emitMessage(
    MobilePiMessage(
      messageId: 'event-$seq-tool-result',
      from: 'node:$nodeId',
      to: 'client',
      type: MessageType.event,
      payload: {
        ProtocolPayloadKeys.streamId: 'task:$taskId',
        ProtocolPayloadKeys.seq: seq,
        ProtocolPayloadKeys.eventType: 'task.output.delta',
        ProtocolPayloadKeys.eventPayload: {
          'taskId': taskId,
          'status': 'running',
          ProtocolPayloadKeys.toolResult: {
            'id': 'call-${seq - 1}',
            'name': name,
            'text': 'ok',
          },
        },
        ProtocolPayloadKeys.createdAt: '2026-01-01T00:00:00.000Z',
      },
      timestamp: DateTime.utc(2026, 1, 1),
    ),
  );
}

class FakeWebSocketService extends WebSocketService {
  final StreamController<MobilePiMessage> _messages =
      StreamController<MobilePiMessage>.broadcast();
  final StreamController<bool> _connections =
      StreamController<bool>.broadcast();
  final List<Map<String, dynamic>> helloPayloads = [];
  final List<Map<String, dynamic>> resumePayloads = [];
  final List<Map<String, dynamic>> taskCreateRequests = [];
  final List<Map<String, dynamic>> followUpRequests = [];
  final List<Map<String, dynamic>> steerRequests = [];
  bool _connected = false;
  String _hubUrl = 'ws://localhost:8080/ws';
  String _tenantKey;
  int connectCount = 0;
  int disconnectCount = 0;
  int forceReconnectCount = 0;

  FakeWebSocketService({String initialTenantKey = 'tenant-a'})
    : _tenantKey = initialTenantKey;

  @override
  Stream<MobilePiMessage> get messageStream => _messages.stream;

  @override
  Stream<bool> get connectionStream => _connections.stream;

  @override
  bool get isConnected => _connected;

  @override
  String get hubUrl => _hubUrl;

  @override
  String get tenantKey => _tenantKey;

  @override
  String updateHubUrl(String url) {
    _hubUrl = WebSocketService.normalizeHubUrl(url);
    return _hubUrl;
  }

  @override
  String updateTenantKey(String key) {
    _tenantKey = WebSocketService.normalizeTenantKey(key);
    return _tenantKey;
  }

  @override
  void connect() {
    connectCount++;
    _connected = true;
    emitConnection(true);
  }

  @override
  void disconnect() {
    disconnectCount++;
    _connected = false;
    emitConnection(false);
  }

  @override
  void forceReconnect() {
    forceReconnectCount++;
    _connected = false;
    connect();
  }

  @override
  void sendHello({Map<String, Map<String, int>> lastCursors = const {}}) {
    helloPayloads.add({
      ProtocolPayloadKeys.tenantKey: _tenantKey,
      'lastCursors': lastCursors,
    });
  }

  @override
  void sendResume(String nodeId, Map<String, int> cursors) {
    resumePayloads.add({'nodeId': nodeId, 'cursors': cursors});
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
    final payload = {
      'nodeId': nodeId,
      'taskId': taskId,
      'prompt': prompt,
      'agentType': agentType,
    };
    if (piInstanceId != null) payload['piInstanceId'] = piInstanceId;
    if (model != null) payload['model'] = model;
    if (projectPath != null) payload['projectPath'] = projectPath;
    taskCreateRequests.add(payload);
  }

  @override
  void sendFollowUpCommand(
    String nodeId,
    String taskId,
    String message, {
    String? sessionPath,
    String? model,
  }) {
    final payload = {'nodeId': nodeId, 'taskId': taskId, 'message': message};
    if (sessionPath != null) payload['sessionPath'] = sessionPath;
    if (model != null) payload['model'] = model;
    followUpRequests.add(payload);
  }

  @override
  void sendSteerCommand(
    String nodeId,
    String taskId,
    String message, {
    String? sessionPath,
    String? model,
  }) {
    final payload = {'nodeId': nodeId, 'taskId': taskId, 'message': message};
    if (sessionPath != null) payload['sessionPath'] = sessionPath;
    if (model != null) payload['model'] = model;
    steerRequests.add(payload);
  }

  void emitMessage(MobilePiMessage message) {
    _messages.add(message);
  }

  void emitConnection(bool connected) {
    _connected = connected;
    _connections.add(connected);
  }

  @override
  void dispose() {
    _messages.close();
    _connections.close();
  }
}
