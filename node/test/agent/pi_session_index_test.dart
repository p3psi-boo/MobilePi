import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:mobilepi_node/agent/pi_session_index.dart';

void main() {
  group('PiSessionIndex.getSessionMessages', () {
    late Directory tempDir;
    late String sessionPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pi_session_test');
      sessionPath = p.join(tempDir.path, 'session_1.jsonl');

      final file = File(sessionPath);
      final sink = file.openWrite();

      // Write header
      sink.writeln(jsonEncode({
        'type': 'session',
        'id': 'test-session-123',
        'cwd': '/test/path',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }));

      // Write session_info
      sink.writeln(jsonEncode({
        'type': 'session_info',
        'name': 'Test Session Name',
      }));

      // Write 25 messages
      for (var i = 1; i <= 25; i++) {
        sink.writeln(jsonEncode({
          'type': 'message',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'message': {
            'role': i % 2 == 0 ? 'user' : 'assistant',
            'content': 'Message content $i',
            'timestamp': 1716200000000 + i * 1000,
          }
        }));
      }

      await sink.close();
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('should fetch the latest page when beforeIndex is null', () async {
      final result = await PiSessionIndex.getSessionMessages(
        sessionPath: sessionPath,
        limit: 10,
      );

      expect(result, isNotNull);
      expect(result!['totalCount'], equals(25));
      expect(result['nextBeforeIndex'], equals(15));

      final messages = result['messages'] as List;
      expect(messages.length, equals(10));
      // First in the list of the sliced result should be message 16
      expect(messages.first['text'], contains('Message content 16'));
      // Last in the list should be message 25
      expect(messages.last['text'], contains('Message content 25'));
    });

    test('should fetch previous page when beforeIndex is specified', () async {
      final result = await PiSessionIndex.getSessionMessages(
        sessionPath: sessionPath,
        limit: 10,
        beforeIndex: 15,
      );

      expect(result, isNotNull);
      expect(result!['totalCount'], equals(25));
      expect(result['nextBeforeIndex'], equals(5));

      final messages = result['messages'] as List;
      expect(messages.length, equals(10));
      expect(messages.first['text'], contains('Message content 6'));
      expect(messages.last['text'], contains('Message content 15'));
    });

    test('should clamp to 0 and return partial list if limit exceeds remaining', () async {
      final result = await PiSessionIndex.getSessionMessages(
        sessionPath: sessionPath,
        limit: 10,
        beforeIndex: 5,
      );

      expect(result, isNotNull);
      expect(result!['totalCount'], equals(25));
      expect(result['nextBeforeIndex'], equals(0));

      final messages = result['messages'] as List;
      expect(messages.length, equals(5));
      expect(messages.first['text'], contains('Message content 1'));
      expect(messages.last['text'], contains('Message content 5'));
    });
  });

  group('PiSessionIndex message usage passthrough', () {
    late Directory tempDir;
    late String sessionPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pi_session_usage_test');
      sessionPath = p.join(tempDir.path, 'session_usage.jsonl');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('preserves usage on assistant message', () async {
      final file = File(sessionPath);
      final sink = file.openWrite();
      sink.writeln(jsonEncode({
        'type': 'session',
        'id': 'usage-session-1',
        'cwd': '/test/path',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }));
      sink.writeln(jsonEncode({
        'type': 'message',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'message': {
          'role': 'assistant',
          'content': 'assistant content',
          'usage': {'input_tokens': 12, 'output_tokens': 34, 'total_tokens': 46},
        }
      }));
      await sink.close();

      final result = await PiSessionIndex.getSessionMessages(
        sessionPath: sessionPath,
        limit: 20,
      );

      expect(result, isNotNull);
      final messages = result!['messages'] as List<dynamic>;
      expect(messages, hasLength(1));
      final usage = messages.first['usage'] as Map<String, dynamic>?;
      expect(usage, isNotNull);
      expect(usage!['input'], equals(12));
      expect(usage['output'], equals(34));
      expect(usage['totalTokens'], equals(46));
    });

    test('missing usage does not crash and remains null', () async {
      final file = File(sessionPath);
      final sink = file.openWrite();
      sink.writeln(jsonEncode({
        'type': 'session',
        'id': 'usage-session-2',
        'cwd': '/test/path',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }));
      sink.writeln(jsonEncode({
        'type': 'message',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'message': {
          'role': 'assistant',
          'content': 'assistant content without usage',
        }
      }));
      await sink.close();

      final result = await PiSessionIndex.getSessionMessages(
        sessionPath: sessionPath,
        limit: 20,
      );

      expect(result, isNotNull);
      final messages = result!['messages'] as List<dynamic>;
      expect(messages, hasLength(1));
      expect(messages.first.containsKey('usage'), isFalse);
    });
  });
}

