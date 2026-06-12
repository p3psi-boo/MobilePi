import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

part 'session_cache.g.dart';

class CachedSessions extends Table {
  TextColumn get taskId => text()();
  TextColumn get nodeId => text()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get payloadJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {taskId};
}

class SessionSnapshot {
  const SessionSnapshot({
    required this.taskId,
    required this.nodeId,
    required this.updatedAt,
    required this.payload,
  });

  final String taskId;
  final String nodeId;
  final DateTime updatedAt;
  final Map<String, dynamic> payload;
}

@DriftDatabase(tables: [CachedSessions])
class SessionCacheDatabase extends _$SessionCacheDatabase {
  SessionCacheDatabase([QueryExecutor? executor])
    : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openConnection() {
    return LazyDatabase(() async {
      final dbFolder = await _databaseDirectory();
      sqlite3.tempDirectory = Directory.systemTemp.path;
      final file = File(p.join(dbFolder.path, 'session-cache.sqlite'));
      return NativeDatabase.createInBackground(file);
    });
  }

  static Future<Directory> _databaseDirectory() async {
    final configured = Platform.environment['MOBILEPI_SESSION_CACHE_DIR'];
    final home = Platform.environment['HOME'];
    final dir = Directory(
      configured != null && configured.trim().isNotEmpty
          ? configured.trim()
          : home != null && home.trim().isNotEmpty
          ? p.join(home.trim(), '.mobilepi')
          : p.join(Directory.systemTemp.path, 'mobilepi'),
    );
    await dir.create(recursive: true);
    return dir;
  }
}

class SessionCache {
  static final SessionCache _shared = SessionCache._();

  factory SessionCache.shared() => _shared;

  SessionCache({SessionCacheDatabase? database})
    : _db = database ?? SessionCacheDatabase();

  SessionCache.inMemory() : _db = SessionCacheDatabase(NativeDatabase.memory());

  SessionCache._() : _db = SessionCacheDatabase();

  final SessionCacheDatabase _db;

  Future<List<SessionSnapshot>> loadRecent({int limit = 200}) async {
    final query = _db.select(_db.cachedSessions)
      ..orderBy([(row) => OrderingTerm.desc(row.updatedAt)])
      ..limit(limit);
    final rows = await query.get();
    return rows
        .map((row) {
          final decoded = jsonDecode(row.payloadJson);
          if (decoded is! Map) return null;
          return SessionSnapshot(
            taskId: row.taskId,
            nodeId: row.nodeId,
            updatedAt: row.updatedAt,
            payload: Map<String, dynamic>.from(decoded),
          );
        })
        .nonNulls
        .toList(growable: false);
  }

  Future<void> saveSnapshots(
    Iterable<SessionSnapshot> snapshots, {
    int keepLatest = 200,
  }) async {
    await _db.batch((batch) {
      batch.insertAllOnConflictUpdate(
        _db.cachedSessions,
        snapshots.map(
          (snapshot) => CachedSessionsCompanion.insert(
            taskId: snapshot.taskId,
            nodeId: snapshot.nodeId,
            updatedAt: snapshot.updatedAt,
            payloadJson: jsonEncode(snapshot.payload),
          ),
        ),
      );
    });
    await _prune(keepLatest);
  }

  Future<void> deleteTask(String taskId) {
    return (_db.delete(
      _db.cachedSessions,
    )..where((row) => row.taskId.equals(taskId))).go();
  }

  Future<void> clear() => _db.delete(_db.cachedSessions).go();

  Future<void> close() => _db.close();

  Future<void> _prune(int keepLatest) async {
    final stale =
        await (_db.select(_db.cachedSessions)
              ..orderBy([(row) => OrderingTerm.desc(row.updatedAt)])
              ..limit(-1, offset: keepLatest))
            .get();
    if (stale.isEmpty) return;
    final staleIds = stale.map((row) => row.taskId).toList();
    await (_db.delete(
      _db.cachedSessions,
    )..where((row) => row.taskId.isIn(staleIds))).go();
  }
}
