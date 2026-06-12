import 'dart:io';

import 'package:mobilepi_node/persistence/node_db.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('NodeDatabase', () {
    late String testDbPath;

    setUp(() {
      final tempDir = Directory.systemTemp.createTempSync('mobilepi_test_');
      testDbPath = p.join(tempDir.path, 'node.db');
    });

    tearDown(() async {
      try {
        final file = File(testDbPath);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    });

    test('initialize creates nodeId and hostname on first run', () async {
      final db = NodeDatabase(dbPath: testDbPath);
      final info = await db.initialize();

      expect(info.containsKey('nodeId'), isTrue);
      expect(info.containsKey('hostname'), isTrue);
      expect(info['nodeId']!.isNotEmpty, isTrue);
      expect(info['hostname']!.isNotEmpty, isTrue);

      db.close();
    });

    test('initialize returns existing data on second run', () async {
      final db1 = NodeDatabase(dbPath: testDbPath);
      final info1 = await db1.initialize();
      db1.close();

      final db2 = NodeDatabase(dbPath: testDbPath);
      final info2 = await db2.initialize();
      db2.close();

      expect(info2['nodeId'], equals(info1['nodeId']));
      expect(info2['hostname'], equals(info1['hostname']));
    });

    test('initialize replaces incompatible legacy replay tables', () async {
      final raw = sqlite3.open(testDbPath);
      raw.execute('CREATE TABLE tasks (id TEXT PRIMARY KEY)');
      raw.execute('CREATE TABLE message_events (msg_id INTEGER PRIMARY KEY)');
      raw.dispose();

      final db = NodeDatabase(dbPath: testDbPath);
      await db.initialize();
      db.close();

      final verify = sqlite3.open(testDbPath);
      final tables = verify
          .select('''
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name IN ('tasks', 'message_events')
            ''')
          .map((row) => row['name'] as String)
          .toList();
      final taskColumns = verify
          .select('PRAGMA table_info(tasks)')
          .map((row) => row['name'] as String)
          .toList();
      verify.dispose();

      expect(tables, contains('tasks'));
      expect(tables, isNot(contains('message_events')));
      expect(taskColumns, contains('stream_id'));
    });

    test(
      'appendEvent assigns per-stream seq and replays after cursor',
      () async {
        final db = NodeDatabase(dbPath: testDbPath);
        await db.initialize();

        final first = db.appendEvent(
          streamId: 'task:1',
          type: 'task.output.delta',
          payload: {'taskId': '1', 'streamingDelta': 'hello'},
        );
        final second = db.appendEvent(
          streamId: 'task:1',
          type: 'task.completed',
          payload: {'taskId': '1', 'status': 'completed'},
        );
        final other = db.appendEvent(
          streamId: 'task:2',
          type: 'task.output.delta',
          payload: {'taskId': '2', 'streamingDelta': 'other'},
        );

        expect(first.seq, 1);
        expect(second.seq, 2);
        expect(other.seq, 1);

        final replay = db.eventsAfter({'task:1': 1});
        expect(replay.map((event) => '${event.streamId}:${event.type}'), [
          'task:1:task.completed',
          'task:2:task.output.delta',
        ]);
        expect(replay.first.payload['status'], 'completed');

        db.close();
      },
    );

    test(
      'eventsAfter preserves global insertion order across streams',
      () async {
        final db = NodeDatabase(dbPath: testDbPath);
        await db.initialize();

        db.appendEvent(
          streamId: 'task:z',
          type: 'task.output.delta',
          payload: {'taskId': 'z', 'streamingDelta': 'first'},
        );
        db.appendEvent(
          streamId: 'task:a',
          type: 'task.output.delta',
          payload: {'taskId': 'a', 'streamingDelta': 'second'},
        );
        db.appendEvent(
          streamId: 'task:z',
          type: 'task.completed',
          payload: {'taskId': 'z', 'status': 'completed'},
        );

        final firstPage = db.eventsAfter({'task:z': 0, 'task:a': 0}, limit: 1);
        expect(firstPage.map((event) => event.streamId), ['task:z']);
        expect(firstPage.single.payload['streamingDelta'], 'first');

        final replay = db.eventsAfter({'task:z': 1, 'task:a': 0});
        expect(replay.map((event) => '${event.streamId}:${event.seq}'), [
          'task:a:1',
          'task:z:2',
        ]);

        db.close();
      },
    );

    test('truncatedStreams returns task snapshot after event purge', () async {
      final db = NodeDatabase(dbPath: testDbPath);
      await db.initialize();

      db.upsertTask(
        taskId: '1',
        streamId: 'task:1',
        agentType: 'pi',
        title: 'Recover me',
        status: 'running',
        projectPath: '/repo',
        model: 'provider/model',
      );
      final old = DateTime.now().toUtc().subtract(const Duration(days: 30));
      db.appendEvent(
        streamId: 'task:1',
        type: 'task.created',
        payload: {'taskId': '1', 'status': 'running'},
        createdAt: old,
      );
      db.appendEvent(
        streamId: 'task:1',
        type: 'task.output.delta',
        payload: {'taskId': '1', 'status': 'running', 'streamingDelta': 'old'},
        createdAt: old,
      );
      db.purgeOldEvents(maxAgeDays: 7);

      final truncated = db.truncatedStreams({'task:1': 0});
      expect(truncated, hasLength(1));
      expect(truncated.single.streamId, 'task:1');
      expect(truncated.single.requestedSeq, 0);
      expect(truncated.single.fromSeq, isNull);
      expect(truncated.single.latestSeq, 2);
      expect(truncated.single.snapshot?.seq, 2);
      expect(truncated.single.snapshot?.type, 'task.snapshot');
      expect(truncated.single.snapshot?.payload['title'], 'Recover me');
      expect(truncated.single.snapshot?.payload['projectPath'], '/repo');

      db.close();
    });
  });
}
