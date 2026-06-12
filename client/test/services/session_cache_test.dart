import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilepi_client/services/session_cache.dart';

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  test('stores and loads recent session snapshots from sqlite', () async {
    final cache = SessionCache.inMemory();
    addTearDown(cache.close);

    await cache.saveSnapshots([
      SessionSnapshot(
        taskId: 'task-old',
        nodeId: 'node-1',
        updatedAt: DateTime.parse('2026-01-01T00:00:00Z'),
        payload: const {'id': 'task-old', 'title': 'old'},
      ),
      SessionSnapshot(
        taskId: 'task-new',
        nodeId: 'node-1',
        updatedAt: DateTime.parse('2026-01-02T00:00:00Z'),
        payload: const {'id': 'task-new', 'title': 'new'},
      ),
    ]);

    final snapshots = await cache.loadRecent();

    expect(snapshots.map((s) => s.taskId), ['task-new', 'task-old']);
    expect(snapshots.first.payload['title'], 'new');
  });

  test('deletes snapshots by task id', () async {
    final cache = SessionCache.inMemory();
    addTearDown(cache.close);

    await cache.saveSnapshots([
      SessionSnapshot(
        taskId: 'task-1',
        nodeId: 'node-1',
        updatedAt: DateTime.parse('2026-01-01T00:00:00Z'),
        payload: const {'id': 'task-1'},
      ),
    ]);
    await cache.deleteTask('task-1');

    expect(await cache.loadRecent(), isEmpty);
  });
}
