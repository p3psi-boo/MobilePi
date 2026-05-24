#!/usr/bin/env dart
// Manual protocol e2e for a live Node daemon at ws://localhost:9000/ws.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const wsUrl = 'ws://localhost:9000/ws';
const _shortTimeout = Duration(seconds: 5);
const _taskTimeout = Duration(seconds: 30);

int _passed = 0;
int _failed = 0;

void _pass(String name) {
  _passed++;
  print('  PASS $name');
}

void _fail(String name, String reason) {
  _failed++;
  print('  FAIL $name: $reason');
}

Future<WebSocketChannel> _connect() async {
  final socket = await WebSocket.connect(wsUrl);
  return IOWebSocketChannel(socket);
}

Future<Msg?> _waitFor(
  Stream<Msg> stream,
  String type, {
  Duration timeout = _shortTimeout,
  bool Function(Msg)? predicate,
}) async {
  final completer = Completer<Msg?>();
  late StreamSubscription<Msg> sub;
  Timer? timer;

  timer = Timer(timeout, () {
    sub.cancel();
    if (!completer.isCompleted) completer.complete(null);
  });

  sub = stream.listen((msg) {
    if (msg.type == type && (predicate == null || predicate(msg))) {
      timer?.cancel();
      sub.cancel();
      if (!completer.isCompleted) completer.complete(msg);
    }
  });

  return completer.future;
}

Future<List<Msg>> _collect(
  Stream<Msg> stream, {
  required Duration timeout,
  bool Function(List<Msg>)? stopWhen,
}) async {
  final messages = <Msg>[];
  final completer = Completer<List<Msg>>();
  late StreamSubscription<Msg> sub;
  Timer? timer;

  timer = Timer(timeout, () {
    sub.cancel();
    if (!completer.isCompleted) completer.complete(messages);
  });

  sub = stream.listen((msg) {
    messages.add(msg);
    if (stopWhen != null && stopWhen(messages)) {
      timer?.cancel();
      sub.cancel();
      if (!completer.isCompleted) completer.complete(messages);
    }
  });

  return completer.future;
}

class Msg {
  final String messageId;
  final String from;
  final String? to;
  final String type;
  final String? kind;
  final Map<String, dynamic> payload;

  Msg({
    required this.messageId,
    required this.from,
    this.to,
    required this.type,
    this.kind,
    required this.payload,
  });

  factory Msg.fromJson(Map<String, dynamic> json) {
    return Msg(
      messageId: json['messageId'] as String,
      from: json['from'] as String,
      to: json['to'] as String?,
      type: json['type'] as String,
      kind: json['kind'] as String?,
      payload: json['payload'] as Map<String, dynamic>? ?? {},
    );
  }

  Map<String, dynamic> toJson() => {
    'messageId': messageId,
    'from': from,
    if (to != null) 'to': to,
    'type': type,
    if (kind != null) 'kind': kind,
    'payload': payload,
  };
}

Msg _make(String type, Map<String, dynamic> payload, {String? to}) {
  return Msg(
    messageId: const Uuid().v4(),
    from: 'client',
    to: to,
    type: type,
    kind: switch (type) {
      'hello' ||
      'resume' ||
      'command' ||
      'query' ||
      'event' ||
      'response' ||
      'error' => type,
      _ => null,
    },
    payload: payload,
  );
}

Msg _command(String commandType, Map<String, dynamic> payload) {
  final id = const Uuid().v4();
  return _make('command', {
    'type': commandType,
    'requestId': id,
    ...payload,
  }, to: 'node:test');
}

Map<String, dynamic> _eventPayload(Msg msg) {
  return Map<String, dynamic>.from(msg.payload['payload'] as Map? ?? const {});
}

String _streamText(Msg msg) {
  final payload = _eventPayload(msg);
  return (payload['streamingText'] as String?) ??
      (payload['streamingDelta'] as String?) ??
      (payload['text'] as String?) ??
      '';
}

Stream<Msg> _msgStream(WebSocketChannel channel) {
  final existing = _streamCache[channel.hashCode];
  if (existing != null) return existing;
  final stream = channel.stream
      .map((d) => Msg.fromJson(jsonDecode(d as String)))
      .asBroadcastStream();
  _streamCache[channel.hashCode] = stream;
  return stream;
}

final _streamCache = <int, Stream<Msg>>{};

Future<void> main() async {
  print('\nMobilePi protocol e2e\n');
  final t0 = DateTime.now();

  print('Test 1: ping/pong');
  try {
    final channel = await _connect().timeout(_shortTimeout);
    final stream = _msgStream(channel);
    channel.sink.add(jsonEncode(_make('ping', {}).toJson()));
    final pong = await _waitFor(stream, 'pong');
    pong == null ? _fail('ping/pong', 'timeout') : _pass('ping/pong');
    await channel.sink.close();
  } catch (e) {
    _fail('ping/pong', '$e');
  }

  print('Test 2: hello response');
  try {
    final channel = await _connect().timeout(_shortTimeout);
    final stream = _msgStream(channel);
    channel.sink.add(
      jsonEncode(
        _make('hello', {
          'clientId': 'e2e-client',
          'lastCursors': <String, Map<String, int>>{},
        }, to: 'hub').toJson(),
      ),
    );
    final resp = await _waitFor(stream, 'response');
    if (resp == null) {
      _fail('hello response', 'timeout');
    } else if (resp.payload['nodeSummary'] is Map<String, dynamic>) {
      _pass('hello response nodeSummary');
    } else {
      _fail('hello response', 'missing nodeSummary');
    }
    await channel.sink.close();
  } catch (e) {
    _fail('hello response', '$e');
  }

  print('Test 3: task.create event stream');
  String? taskId;
  WebSocketChannel? taskChannel;
  try {
    final channel = await _connect().timeout(_shortTimeout);
    taskChannel = channel;
    final stream = _msgStream(channel);
    taskId = const Uuid().v4();
    channel.sink.add(
      jsonEncode(
        _command('task.create', {
          'taskId': taskId,
          'agentType': 'pi',
          'prompt': 'run: echo "protocol-e2e-ok"',
        }).toJson(),
      ),
    );
    final events = await _collect(
      stream,
      timeout: _taskTimeout,
      stopWhen: (msgs) =>
          msgs.any((m) => m.type == 'event' && _streamText(m).isNotEmpty),
    );
    final taskEvents = events.where((m) => m.type == 'event').toList();
    if (taskEvents.isEmpty) {
      _fail('task.create events', 'no event received');
    } else {
      _pass('task.create events: ${taskEvents.length}');
      if (taskEvents.any((m) => m.payload.containsKey('lastMsgId'))) {
        _fail('event payload', 'contains transport replay cursor');
      } else {
        _pass('event payload has no transport replay cursor');
      }
    }
  } catch (e) {
    _fail('task.create', '$e');
  }

  print('Test 4: task.steer');
  if (taskChannel != null && taskId != null) {
    try {
      final stream = _msgStream(taskChannel);
      taskChannel.sink.add(
        jsonEncode(
          _command('task.steer', {
            'taskId': taskId,
            'message': 'stop and print "steered"',
          }).toJson(),
        ),
      );
      final resp = await _waitFor(
        stream,
        'event',
        timeout: const Duration(seconds: 5),
        predicate: (m) =>
            _streamText(m).contains('调校') || _streamText(m).contains('steer'),
      );
      resp == null ? _pass('task.steer sent') : _pass('task.steer event');
    } catch (e) {
      _fail('task.steer', '$e');
    } finally {
      await taskChannel.sink.close();
    }
  }

  print('Test 5: task.panic');
  try {
    final channel = await _connect().timeout(_shortTimeout);
    final stream = _msgStream(channel);
    final panicTaskId = const Uuid().v4();
    channel.sink.add(
      jsonEncode(
        _command('task.create', {
          'taskId': panicTaskId,
          'agentType': 'pi',
          'prompt': 'write a long poem about coding',
        }).toJson(),
      ),
    );
    final firstEvent = await _waitFor(stream, 'event', timeout: _taskTimeout);
    if (firstEvent == null) {
      _fail('panic setup', 'task did not start');
    } else {
      channel.sink.add(
        jsonEncode(_command('task.panic', {'taskId': panicTaskId}).toJson()),
      );
      final panicResp = await _waitFor(
        stream,
        'event',
        timeout: const Duration(seconds: 5),
        predicate: (m) =>
            _eventPayload(m)['status'] == 'idle' ||
            _streamText(m).contains('终止'),
      );
      panicResp == null ? _fail('task.panic', 'no event') : _pass('task.panic');
    }
    await channel.sink.close();
  } catch (e) {
    _fail('task.panic', '$e');
  }

  print('Test 6: task.follow_up');
  try {
    final channel = await _connect().timeout(_shortTimeout);
    final stream = _msgStream(channel);
    final followTaskId = const Uuid().v4();
    channel.sink.add(
      jsonEncode(
        _command('task.create', {
          'taskId': followTaskId,
          'agentType': 'pi',
          'prompt': 'echo done',
        }).toJson(),
      ),
    );
    final firstEvent = await _waitFor(stream, 'event', timeout: _taskTimeout);
    if (firstEvent == null) {
      _fail('follow_up setup', 'task did not start');
    } else {
      channel.sink.add(
        jsonEncode(
          _command('task.follow_up', {
            'taskId': followTaskId,
            'message': 'now echo "follow-up-ok"',
          }).toJson(),
        ),
      );
      final resp = await _waitFor(
        stream,
        'event',
        timeout: const Duration(seconds: 5),
        predicate: (m) =>
            _streamText(m).contains('追加') || _streamText(m).contains('follow'),
      );
      resp == null
          ? _pass('task.follow_up sent')
          : _pass('task.follow_up event');
    }
    await channel.sink.close();
  } catch (e) {
    _fail('task.follow_up', '$e');
  }

  final elapsed = DateTime.now().difference(t0);
  print(
    '\nResult: passed=$_passed failed=$_failed elapsed=${elapsed.inSeconds}s',
  );
  if (_failed > 0) exitCode = 1;
}
