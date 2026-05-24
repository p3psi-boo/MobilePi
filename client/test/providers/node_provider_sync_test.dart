import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilepi_client/providers/node_provider.dart';
import 'package:mobilepi_client/services/websocket_service.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';

void main() {
  group('NodeProvider sync', () {
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
