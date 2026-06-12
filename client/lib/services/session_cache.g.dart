// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'session_cache.dart';

// ignore_for_file: type=lint
class $CachedSessionsTable extends CachedSessions
    with TableInfo<$CachedSessionsTable, CachedSession> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedSessionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _taskIdMeta = const VerificationMeta('taskId');
  @override
  late final GeneratedColumn<String> taskId = GeneratedColumn<String>(
    'task_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nodeIdMeta = const VerificationMeta('nodeId');
  @override
  late final GeneratedColumn<String> nodeId = GeneratedColumn<String>(
    'node_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    taskId,
    nodeId,
    updatedAt,
    payloadJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_sessions';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedSession> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    } else if (isInserting) {
      context.missing(_taskIdMeta);
    }
    if (data.containsKey('node_id')) {
      context.handle(
        _nodeIdMeta,
        nodeId.isAcceptableOrUnknown(data['node_id']!, _nodeIdMeta),
      );
    } else if (isInserting) {
      context.missing(_nodeIdMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {taskId};
  @override
  CachedSession map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedSession(
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}task_id'],
      )!,
      nodeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}node_id'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
    );
  }

  @override
  $CachedSessionsTable createAlias(String alias) {
    return $CachedSessionsTable(attachedDatabase, alias);
  }
}

class CachedSession extends DataClass implements Insertable<CachedSession> {
  final String taskId;
  final String nodeId;
  final DateTime updatedAt;
  final String payloadJson;
  const CachedSession({
    required this.taskId,
    required this.nodeId,
    required this.updatedAt,
    required this.payloadJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['task_id'] = Variable<String>(taskId);
    map['node_id'] = Variable<String>(nodeId);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['payload_json'] = Variable<String>(payloadJson);
    return map;
  }

  CachedSessionsCompanion toCompanion(bool nullToAbsent) {
    return CachedSessionsCompanion(
      taskId: Value(taskId),
      nodeId: Value(nodeId),
      updatedAt: Value(updatedAt),
      payloadJson: Value(payloadJson),
    );
  }

  factory CachedSession.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedSession(
      taskId: serializer.fromJson<String>(json['taskId']),
      nodeId: serializer.fromJson<String>(json['nodeId']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'taskId': serializer.toJson<String>(taskId),
      'nodeId': serializer.toJson<String>(nodeId),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'payloadJson': serializer.toJson<String>(payloadJson),
    };
  }

  CachedSession copyWith({
    String? taskId,
    String? nodeId,
    DateTime? updatedAt,
    String? payloadJson,
  }) => CachedSession(
    taskId: taskId ?? this.taskId,
    nodeId: nodeId ?? this.nodeId,
    updatedAt: updatedAt ?? this.updatedAt,
    payloadJson: payloadJson ?? this.payloadJson,
  );
  CachedSession copyWithCompanion(CachedSessionsCompanion data) {
    return CachedSession(
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      nodeId: data.nodeId.present ? data.nodeId.value : this.nodeId,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedSession(')
          ..write('taskId: $taskId, ')
          ..write('nodeId: $nodeId, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('payloadJson: $payloadJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(taskId, nodeId, updatedAt, payloadJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedSession &&
          other.taskId == this.taskId &&
          other.nodeId == this.nodeId &&
          other.updatedAt == this.updatedAt &&
          other.payloadJson == this.payloadJson);
}

class CachedSessionsCompanion extends UpdateCompanion<CachedSession> {
  final Value<String> taskId;
  final Value<String> nodeId;
  final Value<DateTime> updatedAt;
  final Value<String> payloadJson;
  final Value<int> rowid;
  const CachedSessionsCompanion({
    this.taskId = const Value.absent(),
    this.nodeId = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedSessionsCompanion.insert({
    required String taskId,
    required String nodeId,
    required DateTime updatedAt,
    required String payloadJson,
    this.rowid = const Value.absent(),
  }) : taskId = Value(taskId),
       nodeId = Value(nodeId),
       updatedAt = Value(updatedAt),
       payloadJson = Value(payloadJson);
  static Insertable<CachedSession> custom({
    Expression<String>? taskId,
    Expression<String>? nodeId,
    Expression<DateTime>? updatedAt,
    Expression<String>? payloadJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (taskId != null) 'task_id': taskId,
      if (nodeId != null) 'node_id': nodeId,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedSessionsCompanion copyWith({
    Value<String>? taskId,
    Value<String>? nodeId,
    Value<DateTime>? updatedAt,
    Value<String>? payloadJson,
    Value<int>? rowid,
  }) {
    return CachedSessionsCompanion(
      taskId: taskId ?? this.taskId,
      nodeId: nodeId ?? this.nodeId,
      updatedAt: updatedAt ?? this.updatedAt,
      payloadJson: payloadJson ?? this.payloadJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (taskId.present) {
      map['task_id'] = Variable<String>(taskId.value);
    }
    if (nodeId.present) {
      map['node_id'] = Variable<String>(nodeId.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedSessionsCompanion(')
          ..write('taskId: $taskId, ')
          ..write('nodeId: $nodeId, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$SessionCacheDatabase extends GeneratedDatabase {
  _$SessionCacheDatabase(QueryExecutor e) : super(e);
  $SessionCacheDatabaseManager get managers =>
      $SessionCacheDatabaseManager(this);
  late final $CachedSessionsTable cachedSessions = $CachedSessionsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [cachedSessions];
}

typedef $$CachedSessionsTableCreateCompanionBuilder =
    CachedSessionsCompanion Function({
      required String taskId,
      required String nodeId,
      required DateTime updatedAt,
      required String payloadJson,
      Value<int> rowid,
    });
typedef $$CachedSessionsTableUpdateCompanionBuilder =
    CachedSessionsCompanion Function({
      Value<String> taskId,
      Value<String> nodeId,
      Value<DateTime> updatedAt,
      Value<String> payloadJson,
      Value<int> rowid,
    });

class $$CachedSessionsTableFilterComposer
    extends Composer<_$SessionCacheDatabase, $CachedSessionsTable> {
  $$CachedSessionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get taskId => $composableBuilder(
    column: $table.taskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nodeId => $composableBuilder(
    column: $table.nodeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CachedSessionsTableOrderingComposer
    extends Composer<_$SessionCacheDatabase, $CachedSessionsTable> {
  $$CachedSessionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get taskId => $composableBuilder(
    column: $table.taskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nodeId => $composableBuilder(
    column: $table.nodeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CachedSessionsTableAnnotationComposer
    extends Composer<_$SessionCacheDatabase, $CachedSessionsTable> {
  $$CachedSessionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get taskId =>
      $composableBuilder(column: $table.taskId, builder: (column) => column);

  GeneratedColumn<String> get nodeId =>
      $composableBuilder(column: $table.nodeId, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );
}

class $$CachedSessionsTableTableManager
    extends
        RootTableManager<
          _$SessionCacheDatabase,
          $CachedSessionsTable,
          CachedSession,
          $$CachedSessionsTableFilterComposer,
          $$CachedSessionsTableOrderingComposer,
          $$CachedSessionsTableAnnotationComposer,
          $$CachedSessionsTableCreateCompanionBuilder,
          $$CachedSessionsTableUpdateCompanionBuilder,
          (
            CachedSession,
            BaseReferences<
              _$SessionCacheDatabase,
              $CachedSessionsTable,
              CachedSession
            >,
          ),
          CachedSession,
          PrefetchHooks Function()
        > {
  $$CachedSessionsTableTableManager(
    _$SessionCacheDatabase db,
    $CachedSessionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedSessionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedSessionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedSessionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> taskId = const Value.absent(),
                Value<String> nodeId = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedSessionsCompanion(
                taskId: taskId,
                nodeId: nodeId,
                updatedAt: updatedAt,
                payloadJson: payloadJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String taskId,
                required String nodeId,
                required DateTime updatedAt,
                required String payloadJson,
                Value<int> rowid = const Value.absent(),
              }) => CachedSessionsCompanion.insert(
                taskId: taskId,
                nodeId: nodeId,
                updatedAt: updatedAt,
                payloadJson: payloadJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CachedSessionsTableProcessedTableManager =
    ProcessedTableManager<
      _$SessionCacheDatabase,
      $CachedSessionsTable,
      CachedSession,
      $$CachedSessionsTableFilterComposer,
      $$CachedSessionsTableOrderingComposer,
      $$CachedSessionsTableAnnotationComposer,
      $$CachedSessionsTableCreateCompanionBuilder,
      $$CachedSessionsTableUpdateCompanionBuilder,
      (
        CachedSession,
        BaseReferences<
          _$SessionCacheDatabase,
          $CachedSessionsTable,
          CachedSession
        >,
      ),
      CachedSession,
      PrefetchHooks Function()
    >;

class $SessionCacheDatabaseManager {
  final _$SessionCacheDatabase _db;
  $SessionCacheDatabaseManager(this._db);
  $$CachedSessionsTableTableManager get cachedSessions =>
      $$CachedSessionsTableTableManager(_db, _db.cachedSessions);
}
