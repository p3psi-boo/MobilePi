import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mobilepi_node/agent/agent_runner.dart';
import 'package:mobilepi_node/daemon.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  test('hello node summary does not expose replay cursors', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'mobilepi_daemon_sync_test_',
    );
    final dbPath = p.join(tempDir.path, 'node.db');
    final port = 19000 + DateTime.now().millisecond;
    final daemon = NodeDaemon(
      port: port,
      dbPath: dbPath,
      runnerFactory: (_) => FakeAgentRunner(),
    );

    unawaited(daemon.start());
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final ws = await WebSocket.connect('ws://127.0.0.1:$port/ws');
    final events = <MobilePiMessage>[];
    final sub = ws
        .map((e) => MobilePiMessage.fromJson(jsonDecode(e as String)))
        .listen(events.add);

    ws.add(
      jsonEncode(
        MobilePiMessage(
          messageId: const Uuid().v4(),
          from: 'client',
          to: 'hub',
          type: MessageType.hello,
          payload: {
            'clientId': 'phone-main',
            'lastCursors': {
              'node-x': {'task:old': 999},
            },
          },
        ).toJson(),
      ),
    );

    final response = await _waitFor(
      events,
      (m) => m.type == MessageType.response,
      timeout: const Duration(seconds: 5),
      label: 'hello response',
    );

    expect(response.payload.containsKey('replay'), isFalse);
    expect(response.payload.containsKey('latestMsgId'), isFalse);
    expect(response.payload[ProtocolPayloadKeys.nodeSummary], isA<Map>());
    final nodeSummary = Map<String, dynamic>.from(
      response.payload[ProtocolPayloadKeys.nodeSummary] as Map,
    );
    expect(nodeSummary.containsKey('piMessages'), isTrue);

    await sub.cancel();
    await ws.close();
    await daemon.stop();
    await tempDir.delete(recursive: true);
  });

  test('task updates are live transport events without lastMsgId', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'mobilepi_daemon_task_test_',
    );
    final dbPath = p.join(tempDir.path, 'node.db');
    final port = 20000 + DateTime.now().millisecond;
    final runner = FakeAgentRunner();
    final daemon = NodeDaemon(
      port: port,
      dbPath: dbPath,
      runnerFactory: (_) => runner,
    );

    unawaited(daemon.start());
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final ws = await WebSocket.connect('ws://127.0.0.1:$port/ws');
    final events = <MobilePiMessage>[];
    final sub = ws
        .map((e) => MobilePiMessage.fromJson(jsonDecode(e as String)))
        .listen(events.add);
    final taskId = const Uuid().v4();

    ws.add(
      jsonEncode(
        MobilePiMessage(
          messageId: const Uuid().v4(),
          from: 'client',
          to: 'node:test',
          type: MessageType.command,
          payload: {
            ProtocolPayloadKeys.commandType: 'task.create',
            ProtocolPayloadKeys.requestId: const Uuid().v4(),
            'taskId': taskId,
            'agentType': 'pi',
            'prompt': 'echo live',
          },
        ).toJson(),
      ),
    );

    final update = await _waitFor(
      events,
      (m) =>
          m.type == MessageType.event &&
          _eventPayload(m)['taskId'] == taskId &&
          _eventPayload(m)['streamingDelta'] == 'started',
      timeout: const Duration(seconds: 5),
      label: 'task output event',
    );

    expect(update.payload.containsKey('lastMsgId'), isFalse);

    await sub.cancel();
    await ws.close();
    await daemon.stop();
    await tempDir.delete(recursive: true);
  });

  test(
    'restored session chat uses Pi prompt instead of followUp queue',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'mobilepi_daemon_resume_prompt_test_',
      );
      final dbPath = p.join(tempDir.path, 'node.db');
      final port = 21000 + DateTime.now().millisecond;
      final runner = FakeAgentRunner();
      final daemon = NodeDaemon(
        port: port,
        dbPath: dbPath,
        runnerFactory: (_) => runner,
      );

      unawaited(daemon.start());
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final ws = await WebSocket.connect('ws://127.0.0.1:$port/ws');
      final events = <MobilePiMessage>[];
      final sub = ws
          .map((e) => MobilePiMessage.fromJson(jsonDecode(e as String)))
          .listen(events.add);
      final taskId = const Uuid().v4();

      ws.add(
        jsonEncode(
          MobilePiMessage(
            messageId: const Uuid().v4(),
            from: 'client',
            to: 'node:test',
            type: MessageType.command,
            payload: {
              ProtocolPayloadKeys.commandType: 'task.follow_up',
              ProtocolPayloadKeys.requestId: const Uuid().v4(),
              'taskId': taskId,
              ProtocolPayloadKeys.sessionPath: '/tmp/pi-session.jsonl',
              'message': 'continue from history',
            },
          ).toJson(),
        ),
      );

      await _waitFor(
        events,
        (m) =>
            m.type == MessageType.event &&
            _eventPayload(m)['taskId'] == taskId &&
            _eventPayload(m)['streamingDelta'] ==
                'prompt:continue from history',
        timeout: const Duration(seconds: 5),
        label: 'restored prompt event',
      );

      expect(runner.resumeSessionPaths, ['/tmp/pi-session.jsonl']);
      expect(runner.promptMessages, ['continue from history']);
      expect(runner.followUpMessages, isEmpty);
      expect(runner.steerMessages, isEmpty);

      await sub.cancel();
      await ws.close();
      await daemon.stop();
      await tempDir.delete(recursive: true);
    },
  );

  test('active task followUp still uses Pi follow_up queue', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'mobilepi_daemon_active_followup_test_',
    );
    final dbPath = p.join(tempDir.path, 'node.db');
    final port = 22000 + DateTime.now().millisecond;
    final runner = FakeAgentRunner();
    final daemon = NodeDaemon(
      port: port,
      dbPath: dbPath,
      runnerFactory: (_) => runner,
    );

    unawaited(daemon.start());
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final ws = await WebSocket.connect('ws://127.0.0.1:$port/ws');
    final events = <MobilePiMessage>[];
    final sub = ws
        .map((e) => MobilePiMessage.fromJson(jsonDecode(e as String)))
        .listen(events.add);
    final taskId = const Uuid().v4();

    ws.add(
      jsonEncode(
        MobilePiMessage(
          messageId: const Uuid().v4(),
          from: 'client',
          to: 'node:test',
          type: MessageType.command,
          payload: {
            ProtocolPayloadKeys.commandType: 'task.create',
            ProtocolPayloadKeys.requestId: const Uuid().v4(),
            'taskId': taskId,
            'agentType': 'pi',
            'prompt': 'start',
          },
        ).toJson(),
      ),
    );

    await _waitFor(
      events,
      (m) =>
          m.type == MessageType.event &&
          _eventPayload(m)['taskId'] == taskId &&
          _eventPayload(m)['streamingDelta'] == 'started',
      timeout: const Duration(seconds: 5),
      label: 'initial event',
    );

    ws.add(
      jsonEncode(
        MobilePiMessage(
          messageId: const Uuid().v4(),
          from: 'client',
          to: 'node:test',
          type: MessageType.command,
          payload: {
            ProtocolPayloadKeys.commandType: 'task.follow_up',
            ProtocolPayloadKeys.requestId: const Uuid().v4(),
            'taskId': taskId,
            'message': 'queue after current turn',
          },
        ).toJson(),
      ),
    );

    await _waitFor(
      events,
      (m) =>
          m.type == MessageType.event &&
          _eventPayload(m)['taskId'] == taskId &&
          (_eventPayload(m)['streamingDelta'] as String? ?? '').contains(
            'followUp:queue after current turn',
          ),
      timeout: const Duration(seconds: 5),
      label: 'active followUp event',
    );

    expect(runner.promptMessages, isEmpty);
    expect(runner.followUpMessages, ['queue after current turn']);

    await sub.cancel();
    await ws.close();
    await daemon.stop();
    await tempDir.delete(recursive: true);
  });

  test(
    'protocol command events are persisted and replayed by cursor',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'mobilepi_daemon_protocol_replay_test_',
      );
      final dbPath = p.join(tempDir.path, 'node.db');
      final port = 23000 + DateTime.now().millisecond;
      final runner = FakeAgentRunner();
      final daemon = NodeDaemon(
        port: port,
        dbPath: dbPath,
        runnerFactory: (_) => runner,
      );

      unawaited(daemon.start());
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final ws = await WebSocket.connect('ws://127.0.0.1:$port/ws');
      final events = <MobilePiMessage>[];
      final sub = ws
          .map((e) => MobilePiMessage.fromJson(jsonDecode(e as String)))
          .listen(events.add);
      final taskId = const Uuid().v4();

      ws.add(
        jsonEncode(
          MobilePiMessage(
            messageId: 'cmd-1',
            from: 'client',
            to: 'node:test',
            type: MessageType.command,
            payload: {
              ProtocolPayloadKeys.commandType: 'task.create',
              ProtocolPayloadKeys.requestId: 'cmd-1',
              'taskId': taskId,
              'agentType': 'pi',
              'prompt': 'echo replay',
            },
          ).toJson(),
        ),
      );

      final liveEvent = await _waitFor(
        events,
        (m) =>
            m.type == MessageType.event &&
            m.payload[ProtocolPayloadKeys.streamId] == 'task:$taskId' &&
            ((m.payload[ProtocolPayloadKeys.eventPayload]
                            as Map<String, dynamic>)['streamingDelta']
                        as String? ??
                    '') ==
                'started',
        timeout: const Duration(seconds: 5),
        label: 'protocol task event',
      );

      expect(liveEvent.kind, 'event');
      expect(liveEvent.payload[ProtocolPayloadKeys.seq], isA<int>());

      ws.add(
        jsonEncode(
          MobilePiMessage(
            messageId: 'resume-1',
            from: 'client',
            to: 'node:test',
            type: MessageType.resume,
            payload: {
              ProtocolPayloadKeys.cursors: {'task:$taskId': 0},
            },
          ).toJson(),
        ),
      );

      final replay = await _waitFor(
        events,
        (m) =>
            m.type == MessageType.response &&
            m.payload[ProtocolPayloadKeys.responseTo] == 'resume-1',
        timeout: const Duration(seconds: 5),
        label: 'resume replay response',
      );
      final replayEvents = replay.payload[ProtocolPayloadKeys.events] as List;
      expect(
        replayEvents.any(
          (event) =>
              event[ProtocolPayloadKeys.streamId] == 'task:$taskId' &&
              event[ProtocolPayloadKeys.eventType] == 'task.output.delta',
        ),
        isTrue,
      );

      await sub.cancel();
      await ws.close();
      await daemon.stop();
      await tempDir.delete(recursive: true);
    },
  );
}

class FakeAgentRunner implements AgentRunner {
  final _controller = StreamController<AgentEvent>.broadcast();
  final promptMessages = <String>[];
  final steerMessages = <String>[];
  final followUpMessages = <String>[];
  final resumeSessionPaths = <String>[];
  var _running = false;

  @override
  String get agentType => 'pi';

  @override
  bool get isRunning => _running;

  @override
  Stream<AgentEvent> get eventStream => _controller.stream;

  @override
  Future<void> start(String taskId, String prompt, {String? model}) async {
    _running = true;
    _controller.add(
      const AgentEvent(state: AgentRunState.running, streamingText: 'started'),
    );
  }

  @override
  Future<void> prompt(String message) async {
    promptMessages.add(message);
    _controller.add(
      AgentEvent(
        state: AgentRunState.running,
        streamingText: 'prompt:$message',
      ),
    );
  }

  @override
  Future<void> steer(String message) async {
    steerMessages.add(message);
    _controller.add(
      AgentEvent(state: AgentRunState.running, streamingText: 'steer:$message'),
    );
  }

  @override
  Future<void> followUp(String message) async {
    followUpMessages.add(message);
    _controller.add(
      AgentEvent(
        state: AgentRunState.running,
        streamingText: 'followUp:$message',
      ),
    );
  }

  @override
  Future<void> resumeSession(
    String taskId,
    String sessionPath, {
    String? model,
  }) async {
    _running = true;
    resumeSessionPaths.add(sessionPath);
  }

  @override
  Future<void> abort() async {
    _running = false;
    await _controller.close();
  }
}

Future<MobilePiMessage> _waitFor(
  List<MobilePiMessage> events,
  bool Function(MobilePiMessage) predicate, {
  required Duration timeout,
  required String label,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    for (final event in events) {
      if (predicate(event)) return event;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('Timed out waiting for $label. Saw ${events.length} events.');
}

Map<String, dynamic> _eventPayload(MobilePiMessage message) {
  return Map<String, dynamic>.from(
    message.payload[ProtocolPayloadKeys.eventPayload] as Map,
  );
}
