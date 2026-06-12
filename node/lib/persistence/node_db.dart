import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

/// Node 本地持久化 — SQLite 微型账本。
///
/// Node identity、task metadata 与 append-only event log 都在这里落盘。
/// Pi session files 仍然是 transcript 的事实源；MobilePi events 只负责
/// 让 Client 在断线后恢复实时任务投影。
class NodeDatabase {
  late Database _db;
  final String _dbPath;

  NodeDatabase({String? dbPath}) : _dbPath = dbPath ?? _defaultDbPath();

  static String _defaultDbPath() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.mobilepi', 'node.db');
  }

  /// 初始化数据库，创建表，返回节点信息
  Future<Map<String, String>> initialize() async {
    final dir = Directory(p.dirname(_dbPath));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    _db = sqlite3.open(_dbPath);
    _db.execute('PRAGMA journal_mode=WAL;');
    _db.execute('PRAGMA busy_timeout=5000;');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS node_info (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        node_id TEXT NOT NULL,
        hostname TEXT NOT NULL,
        created_at TEXT,
        updated_at TEXT NOT NULL
      )
    ''');
    _ensureColumn('node_info', 'created_at', 'TEXT');
    _dropTableIfExists('message_events');
    if (_tableExists('tasks') &&
        !_tableColumns('tasks').contains('stream_id')) {
      _dropTableIfExists('tasks');
    }

    _db.execute('''
      CREATE TABLE IF NOT EXISTS tasks (
        task_id TEXT PRIMARY KEY,
        stream_id TEXT NOT NULL UNIQUE,
        agent_type TEXT NOT NULL,
        project_path TEXT,
        title TEXT NOT NULL,
        status TEXT NOT NULL,
        model TEXT,
        session_id TEXT,
        session_path TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        completed_at TEXT
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        stream_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        type TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        ttl_policy TEXT NOT NULL DEFAULT 'normal',
        UNIQUE(stream_id, seq)
      )
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS events_stream_seq_idx ON events(stream_id, seq)',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS events_created_at_idx ON events(created_at)',
    );

    _db.execute('''
      CREATE TABLE IF NOT EXISTS stream_cursors (
        stream_id TEXT PRIMARY KEY,
        next_seq INTEGER NOT NULL
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS command_requests (
        request_id TEXT PRIMARY KEY,
        command_type TEXT NOT NULL,
        task_id TEXT,
        result_json TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS artifacts (
        artifact_id TEXT PRIMARY KEY,
        task_id TEXT,
        kind TEXT NOT NULL,
        content_type TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        local_path TEXT NOT NULL,
        sha256 TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS artifacts_task_idx ON artifacts(task_id)',
    );

    final row = _db.select(
      'SELECT node_id, hostname FROM node_info WHERE id = 1',
    );

    if (row.isEmpty) {
      final nodeId = const Uuid().v4();
      final hostname = Platform.localHostname;
      final now = DateTime.now().toUtc().toIso8601String();

      _db.execute(
        '''
        INSERT INTO node_info (id, node_id, hostname, created_at, updated_at)
        VALUES (1, ?, ?, ?, ?)
      ''',
        [nodeId, hostname, now, now],
      );

      return {'nodeId': nodeId, 'hostname': hostname};
    } else {
      return {
        'nodeId': row.first['node_id'] as String,
        'hostname': row.first['hostname'] as String,
      };
    }
  }

  void _ensureColumn(String table, String column, String definition) {
    final columns = _tableColumns(table);
    if (!columns.contains(column)) {
      _db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }

  bool _tableExists(String table) {
    final rows = _db.select(
      '''
      SELECT name FROM sqlite_master
      WHERE type = 'table' AND name = ?
      ''',
      [table],
    );
    return rows.isNotEmpty;
  }

  Set<String> _tableColumns(String table) {
    return _db
        .select('PRAGMA table_info($table)')
        .map((row) => row['name'] as String)
        .toSet();
  }

  void _dropTableIfExists(String table) {
    _db.execute('DROP TABLE IF EXISTS $table');
  }

  void upsertTask({
    required String taskId,
    required String streamId,
    required String agentType,
    required String title,
    required String status,
    String? projectPath,
    String? model,
    String? sessionId,
    String? sessionPath,
    DateTime? createdAt,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final created = (createdAt ?? DateTime.now().toUtc()).toIso8601String();
    _db.execute(
      '''
      INSERT INTO tasks (
        task_id, stream_id, agent_type, project_path, title, status, model,
        session_id, session_path, created_at, updated_at, completed_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
      ON CONFLICT(task_id) DO UPDATE SET
        stream_id = excluded.stream_id,
        agent_type = excluded.agent_type,
        project_path = excluded.project_path,
        title = excluded.title,
        status = excluded.status,
        model = excluded.model,
        session_id = excluded.session_id,
        session_path = excluded.session_path,
        updated_at = excluded.updated_at,
        completed_at = CASE
          WHEN excluded.status IN ('completed', 'idle', 'error') THEN excluded.updated_at
          ELSE tasks.completed_at
        END
      ''',
      [
        taskId,
        streamId,
        agentType,
        projectPath,
        title,
        status,
        model,
        sessionId,
        sessionPath,
        created,
        now,
      ],
    );
  }

  void updateTaskStatus(String taskId, String status) {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute(
      '''
      UPDATE tasks
      SET status = ?,
          updated_at = ?,
          completed_at = CASE
            WHEN ? IN ('completed', 'idle', 'error') THEN ?
            ELSE completed_at
          END
      WHERE task_id = ?
      ''',
      [status, now, status, now, taskId],
    );
  }

  NodeEventRecord appendEvent({
    required String streamId,
    required String type,
    required Map<String, dynamic> payload,
    String ttlPolicy = 'normal',
    DateTime? createdAt,
  }) {
    final created = (createdAt ?? DateTime.now().toUtc()).toIso8601String();
    _db.execute('BEGIN IMMEDIATE');
    try {
      final rows = _db.select(
        'SELECT next_seq FROM stream_cursors WHERE stream_id = ?',
        [streamId],
      );
      final seq = rows.isEmpty ? 1 : rows.first['next_seq'] as int;
      if (rows.isEmpty) {
        _db.execute(
          'INSERT INTO stream_cursors (stream_id, next_seq) VALUES (?, ?)',
          [streamId, seq + 1],
        );
      } else {
        _db.execute(
          'UPDATE stream_cursors SET next_seq = ? WHERE stream_id = ?',
          [seq + 1, streamId],
        );
      }
      _db.execute(
        '''
        INSERT INTO events (stream_id, seq, type, payload_json, created_at, ttl_policy)
        VALUES (?, ?, ?, ?, ?, ?)
        ''',
        [streamId, seq, type, jsonEncode(payload), created, ttlPolicy],
      );
      _db.execute('COMMIT');
      return NodeEventRecord(
        streamId: streamId,
        seq: seq,
        type: type,
        payload: payload,
        createdAt: created,
      );
    } catch (e, st) {
      final log = Logger('NodeDatabase');
      log.warning('event=db.append_event_failed streamId=$streamId', e, st);
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<NodeEventRecord> eventsAfter(
    Map<String, int> cursors, {
    int limit = 500,
  }) {
    if (limit <= 0) return const <NodeEventRecord>[];

    if (cursors.isEmpty) {
      return _eventRows(
        _db.select(
          '''
          SELECT stream_id, seq, type, payload_json, created_at
          FROM events
          ORDER BY id
          LIMIT ?
          ''',
          [limit],
        ),
      );
    }

    _db.execute('''
      CREATE TEMP TABLE IF NOT EXISTS replay_cursors (
        stream_id TEXT PRIMARY KEY,
        seq INTEGER NOT NULL
      )
    ''');
    _db.execute('DELETE FROM replay_cursors');
    try {
      for (final entry in cursors.entries) {
        _db.execute(
          '''
          INSERT INTO replay_cursors (stream_id, seq)
          VALUES (?, ?)
          ''',
          [entry.key, entry.value],
        );
      }
      final rows = _db.select(
        '''
        SELECT e.stream_id, e.seq, e.type, e.payload_json, e.created_at
        FROM events e
        LEFT JOIN replay_cursors c ON c.stream_id = e.stream_id
        WHERE e.seq > COALESCE(c.seq, 0)
        ORDER BY e.id
        LIMIT ?
        ''',
        [limit],
      );
      return _eventRows(rows);
    } catch (e, st) {
      final log = Logger('NodeDatabase');
      log.warning('event=db.events_after_failed', e, st);
      rethrow;
    }
  }

  List<NodeTruncatedStream> truncatedStreams(Map<String, int> cursors) {
    if (cursors.isEmpty) return const <NodeTruncatedStream>[];

    final truncated = <NodeTruncatedStream>[];
    for (final entry in cursors.entries) {
      final streamRows = _db.select(
        '''
        SELECT next_seq FROM stream_cursors
        WHERE stream_id = ?
        ''',
        [entry.key],
      );
      if (streamRows.isEmpty) continue;

      final nextSeq = streamRows.first['next_seq'] as int;
      final latestSeq = nextSeq - 1;
      if (entry.value >= latestSeq) continue;

      final minRows = _db.select(
        '''
        SELECT MIN(seq) AS min_seq FROM events
        WHERE stream_id = ?
        ''',
        [entry.key],
      );
      final minSeq = minRows.first['min_seq'] as int?;
      if (minSeq != null && entry.value >= minSeq - 1) continue;

      final snapshot = taskSnapshotForStream(entry.key, seq: latestSeq);
      truncated.add(
        NodeTruncatedStream(
          streamId: entry.key,
          requestedSeq: entry.value,
          fromSeq: minSeq,
          latestSeq: latestSeq,
          snapshot: snapshot,
        ),
      );
    }
    return truncated;
  }

  NodeEventRecord? taskSnapshotForStream(String streamId, {int? seq}) {
    final rows = _db.select(
      '''
      SELECT task_id, stream_id, agent_type, project_path, title, status, model,
             session_id, session_path, created_at, updated_at
      FROM tasks
      WHERE stream_id = ?
      LIMIT 1
      ''',
      [streamId],
    );
    if (rows.isEmpty) return null;

    final row = rows.first;
    final taskId = row['task_id'] as String;
    final payload = <String, dynamic>{
      'taskId': taskId,
      'agentType': row['agent_type'] as String,
      'status': row['status'] as String,
      ProtocolPayloadKeys.title: row['title'] as String,
    };
    final projectPath = row['project_path'] as String?;
    if (projectPath != null) {
      payload[ProtocolPayloadKeys.projectPath] = projectPath;
    }
    final model = row['model'] as String?;
    if (model != null) {
      payload[ProtocolPayloadKeys.model] = model;
    }
    final sessionId = row['session_id'] as String?;
    if (sessionId != null) {
      payload['sessionId'] = sessionId;
    }
    final sessionPath = row['session_path'] as String?;
    if (sessionPath != null) {
      payload[ProtocolPayloadKeys.sessionPath] = sessionPath;
    }
    return NodeEventRecord(
      streamId: streamId,
      seq: seq ?? _latestSeqForStream(streamId),
      type: 'task.snapshot',
      payload: payload,
      createdAt: row['updated_at'] as String,
    );
  }

  int _latestSeqForStream(String streamId) {
    final rows = _db.select(
      '''
      SELECT next_seq FROM stream_cursors
      WHERE stream_id = ?
      ''',
      [streamId],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['next_seq'] as int) - 1;
  }

  Map<String, dynamic>? commandResult(String requestId) {
    final rows = _db.select(
      'SELECT result_json FROM command_requests WHERE request_id = ?',
      [requestId],
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['result_json'] as String?;
    if (raw == null || raw.isEmpty) return const <String, dynamic>{};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  bool insertCommandRequest({
    required String requestId,
    required String commandType,
    String? taskId,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      _db.execute(
        '''
        INSERT INTO command_requests (request_id, command_type, task_id, created_at)
        VALUES (?, ?, ?, ?)
        ''',
        [requestId, commandType, taskId, now],
      );
      return true;
    } on SqliteException {
      return false;
    }
  }

  void completeCommandRequest(String requestId, Map<String, dynamic> result) {
    _db.execute(
      'UPDATE command_requests SET result_json = ? WHERE request_id = ?',
      [jsonEncode(result), requestId],
    );
  }

  List<NodeEventRecord> _eventRows(ResultSet rows) {
    return rows.map((row) {
      final payload = jsonDecode(row['payload_json'] as String);
      return NodeEventRecord(
        streamId: row['stream_id'] as String,
        seq: row['seq'] as int,
        type: row['type'] as String,
        payload: Map<String, dynamic>.from(payload as Map),
        createdAt: row['created_at'] as String,
      );
    }).toList();
  }

  /// Purge old events to prevent unbounded DB growth.
  void purgeOldEvents({int maxAgeDays = 7, int keepPerStream = 500}) {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(Duration(days: maxAgeDays))
        .toIso8601String();
    _db.execute('DELETE FROM events WHERE created_at < ?', [cutoff]);
  }

  void close() {
    purgeOldEvents();
    _db.dispose();
  }
}

class NodeEventRecord {
  final String streamId;
  final int seq;
  final String type;
  final Map<String, dynamic> payload;
  final String createdAt;

  const NodeEventRecord({
    required this.streamId,
    required this.seq,
    required this.type,
    required this.payload,
    required this.createdAt,
  });

  Map<String, dynamic> toProtocolPayload() {
    final taskId = payload['taskId'];
    return {
      'streamId': streamId,
      'seq': seq,
      'type': type,
      'taskId': ?taskId,
      'payload': payload,
      'createdAt': createdAt,
    };
  }
}

class NodeTruncatedStream {
  final String streamId;
  final int requestedSeq;
  final int? fromSeq;
  final int latestSeq;
  final NodeEventRecord? snapshot;

  const NodeTruncatedStream({
    required this.streamId,
    required this.requestedSeq,
    required this.fromSeq,
    required this.latestSeq,
    required this.snapshot,
  });

  Map<String, dynamic> toProtocolPayload() {
    return {
      ProtocolPayloadKeys.streamId: streamId,
      'requestedSeq': requestedSeq,
      'fromSeq': fromSeq,
      'latestSeq': latestSeq,
      if (snapshot != null) 'snapshot': snapshot!.toProtocolPayload(),
    };
  }
}
