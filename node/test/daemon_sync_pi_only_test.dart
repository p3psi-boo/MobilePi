import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mobilepi_node/agent/agent_runner.dart';
import 'package:mobilepi_node/daemon.dart';
import 'package:mobilepi_node/persistence/node_db.dart';
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
    'task output delta preserves long payloads without truncation',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'mobilepi_daemon_long_delta_test_',
      );
      final dbPath = p.join(tempDir.path, 'node.db');
      final port = 20500 + DateTime.now().millisecond;
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
              'prompt': 'emit long output',
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
        label: 'long-output task started event',
      );

      final longDelta = 'x' * 24000;
      runner.emitStreamingText(longDelta);

      final update = await _waitFor(
        events,
        (m) =>
            m.type == MessageType.event &&
            _eventPayload(m)['taskId'] == taskId &&
            _eventPayload(m)['streamingDelta'] == longDelta,
        timeout: const Duration(seconds: 5),
        label: 'untruncated long delta event',
      );

      final delta = _eventPayload(update)['streamingDelta'] as String;
      expect(delta, hasLength(longDelta.length));
      expect(delta, isNot(contains('...(truncated)...')));

      await sub.cancel();
      await ws.close();
      await daemon.stop();
      await tempDir.delete(recursive: true);
    },
  );

  test('live tool events preserve call ids in protocol payloads', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'mobilepi_daemon_tool_event_test_',
    );
    final dbPath = p.join(tempDir.path, 'node.db');
    final port = 20600 + DateTime.now().millisecond;
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
            'prompt': 'emit tool events',
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
      label: 'tool task started event',
    );

    runner.emitToolCall('call-1', 'read_file');
    final toolCallEvent = await _waitFor(
      events,
      (m) {
        if (m.type != MessageType.event) return false;
        final payload = _eventPayload(m);
        final toolCall = payload[ProtocolPayloadKeys.toolCall];
        return payload['taskId'] == taskId &&
            toolCall is Map &&
            toolCall['id'] == 'call-1';
      },
      timeout: const Duration(seconds: 5),
      label: 'tool call event',
    );

    runner.emitToolResult('call-1', 'read_file', 'file contents');
    final toolResultEvent = await _waitFor(
      events,
      (m) {
        if (m.type != MessageType.event) return false;
        final payload = _eventPayload(m);
        final toolResult = payload[ProtocolPayloadKeys.toolResult];
        return payload['taskId'] == taskId &&
            toolResult is Map &&
            toolResult['id'] == 'call-1';
      },
      timeout: const Duration(seconds: 5),
      label: 'tool result event',
    );

    final toolCall = Map<String, dynamic>.from(
      _eventPayload(toolCallEvent)[ProtocolPayloadKeys.toolCall] as Map,
    );
    final toolResult = Map<String, dynamic>.from(
      _eventPayload(toolResultEvent)[ProtocolPayloadKeys.toolResult] as Map,
    );
    expect(toolCall, containsPair('name', 'read_file'));
    expect(toolResult, containsPair('name', 'read_file'));
    expect(toolResult, containsPair('text', 'file contents'));
    expect(toolResult, containsPair('isError', false));

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

  test('external session append emits live delta events', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'mobilepi_daemon_external_sync_test_',
    );
    final dbPath = p.join(tempDir.path, 'node.db');
    final sessionPath = p.join(tempDir.path, 'session.jsonl');
    await File(sessionPath).writeAsString('');
    final port = 23500 + DateTime.now().millisecond;
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
            ProtocolPayloadKeys.sessionPath: sessionPath,
            'message': 'resume and watch',
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
            'prompt:resume and watch',
          ),
      timeout: const Duration(seconds: 5),
      label: 'resume prompt event',
    );

    await File(sessionPath).writeAsString(
      '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"external live delta"}]}}\n',
      mode: FileMode.append,
    );

    await _waitFor(
      events,
      (m) =>
          m.type == MessageType.event &&
          _eventPayload(m)['taskId'] == taskId &&
          (_eventPayload(m)['streamingDelta'] as String? ?? '').contains(
            'external live delta',
          ),
      timeout: const Duration(seconds: 8),
      label: 'external session delta event',
    );

    await sub.cancel();
    await ws.close();
    await daemon.stop();
    await tempDir.delete(recursive: true);
  });

  test('external session watcher preserves split UTF-8 lines', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'mobilepi_daemon_utf8_tail_test_',
    );
    final dbPath = p.join(tempDir.path, 'node.db');
    final sessionPath = p.join(tempDir.path, 'session.jsonl');
    await File(sessionPath).writeAsString('');
    final port = 23600 + DateTime.now().millisecond;
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
            ProtocolPayloadKeys.sessionPath: sessionPath,
            'message': 'resume and watch utf8',
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
            'prompt:resume and watch utf8',
          ),
      timeout: const Duration(seconds: 5),
      label: 'utf8 resume prompt event',
    );

    final line =
        '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"中文 live delta"}]}}\n';
    final bytes = utf8.encode(line);
    final splitAt = bytes.indexOf(0xe4) + 1;
    expect(splitAt, greaterThan(0));
    final file = File(sessionPath);
    await file.writeAsBytes(
      bytes.take(splitAt).toList(),
      mode: FileMode.append,
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await file.writeAsBytes(
      bytes.skip(splitAt).toList(),
      mode: FileMode.append,
    );

    await _waitFor(
      events,
      (m) =>
          m.type == MessageType.event &&
          _eventPayload(m)['taskId'] == taskId &&
          (_eventPayload(m)['streamingDelta'] as String? ?? '') ==
              '中文 live delta',
      timeout: const Duration(seconds: 8),
      label: 'split utf8 session delta event',
    );

    await sub.cancel();
    await ws.close();
    await daemon.stop();
    await tempDir.delete(recursive: true);
  });

  test(
    'external session watcher emits identical deltas from distinct lines',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'mobilepi_daemon_tail_offset_dedupe_test_',
      );
      final dbPath = p.join(tempDir.path, 'node.db');
      final sessionPath = p.join(tempDir.path, 'session.jsonl');
      await File(sessionPath).writeAsString('');
      final port = 23700 + DateTime.now().millisecond;
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
              ProtocolPayloadKeys.sessionPath: sessionPath,
              'message': 'resume and watch repeated lines',
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
              'prompt:resume and watch repeated lines',
            ),
        timeout: const Duration(seconds: 5),
        label: 'repeated-lines resume prompt event',
      );

      const repeatedLine =
          '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"same live delta"}]}}\n';
      await File(
        sessionPath,
      ).writeAsString('$repeatedLine$repeatedLine', mode: FileMode.append);

      await _waitFor(
        events,
        (m) =>
            events
                .where(
                  (event) =>
                      event.type == MessageType.event &&
                      _eventPayload(event)['taskId'] == taskId &&
                      (_eventPayload(event)['streamingDelta'] as String? ??
                              '') ==
                          'same live delta',
                )
                .length >=
            2,
        timeout: const Duration(seconds: 8),
        label: 'two identical session delta events',
      );

      await sub.cancel();
      await ws.close();
      await daemon.stop();
      await tempDir.delete(recursive: true);
    },
  );

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

  test('resume paginates replay events with hasMore', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'mobilepi_daemon_resume_pagination_test_',
    );
    final dbPath = p.join(tempDir.path, 'node.db');
    final db = NodeDatabase(dbPath: dbPath);
    await db.initialize();
    db.upsertTask(
      taskId: 'bulk',
      streamId: 'task:bulk',
      agentType: 'pi',
      title: 'Bulk replay',
      status: 'running',
    );
    for (var i = 1; i <= 501; i++) {
      db.appendEvent(
        streamId: 'task:bulk',
        type: 'task.output.delta',
        payload: {
          'taskId': 'bulk',
          'status': 'running',
          'streamingDelta': '$i\n',
        },
      );
    }
    db.close();

    final port = 24000 + DateTime.now().millisecond;
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
          messageId: 'resume-page-1',
          from: 'client',
          to: 'node:test',
          type: MessageType.resume,
          payload: {
            ProtocolPayloadKeys.cursors: {'task:bulk': 0},
          },
        ).toJson(),
      ),
    );

    final first = await _waitFor(
      events,
      (m) =>
          m.type == MessageType.response &&
          m.payload[ProtocolPayloadKeys.responseTo] == 'resume-page-1',
      timeout: const Duration(seconds: 5),
      label: 'first resume page',
    );
    final firstEvents = first.payload[ProtocolPayloadKeys.events] as List;
    expect(firstEvents, hasLength(500));
    expect(first.payload[ProtocolPayloadKeys.hasMore], isTrue);
    expect(firstEvents.last[ProtocolPayloadKeys.seq], 500);

    ws.add(
      jsonEncode(
        MobilePiMessage(
          messageId: 'resume-page-2',
          from: 'client',
          to: 'node:test',
          type: MessageType.resume,
          payload: {
            ProtocolPayloadKeys.cursors: {'task:bulk': 500},
          },
        ).toJson(),
      ),
    );

    final second = await _waitFor(
      events,
      (m) =>
          m.type == MessageType.response &&
          m.payload[ProtocolPayloadKeys.responseTo] == 'resume-page-2',
      timeout: const Duration(seconds: 5),
      label: 'second resume page',
    );
    final secondEvents = second.payload[ProtocolPayloadKeys.events] as List;
    expect(secondEvents, hasLength(1));
    expect(second.payload[ProtocolPayloadKeys.hasMore], isFalse);
    expect(secondEvents.single[ProtocolPayloadKeys.seq], 501);

    await sub.cancel();
    await ws.close();
    await daemon.stop();
    await tempDir.delete(recursive: true);
  });

  test('responses are addressed to the requesting client', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'mobilepi_daemon_reply_target_test_',
    );
    final dbPath = p.join(tempDir.path, 'node.db');
    final port = 21000 + DateTime.now().millisecond;
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
          from: 'phone-xyz',
          to: 'node:test',
          type: MessageType.resume,
          payload: const {
            ProtocolPayloadKeys.cursors: <String, dynamic>{},
            ProtocolPayloadKeys.includeNodeSummary: true,
          },
        ).toJson(),
      ),
    );

    final response = await _waitFor(
      events,
      (m) => m.type == MessageType.response,
      timeout: const Duration(seconds: 5),
      label: 'resume response',
    );

    // 精确路由：回执 to 指向具体请求方 clientId，而非广播哨兵 'client'。
    expect(response.to, 'phone-xyz');

    await sub.cancel();
    await ws.close();
    await daemon.stop();
    await tempDir.delete(recursive: true);
  });
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

  void emitStreamingText(String text) {
    _controller.add(
      AgentEvent(state: AgentRunState.running, streamingText: text),
    );
  }

  void emitToolCall(String id, String name) {
    _controller.add(
      AgentEvent(state: AgentRunState.running, toolCallId: id, toolName: name),
    );
  }

  void emitToolResult(String id, String name, String text) {
    _controller.add(
      AgentEvent(
        state: AgentRunState.running,
        toolCallId: id,
        toolName: name,
        toolResult: text,
        toolResultIsError: false,
      ),
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
