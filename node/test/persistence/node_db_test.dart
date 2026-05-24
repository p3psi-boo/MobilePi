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
        expect(replay.map((event) => event.type), ['task.completed']);
        expect(replay.single.payload['status'], 'completed');

        db.close();
      },
    );
  });
}
