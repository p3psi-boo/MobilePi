# Database Guidelines

> Backend database conventions for MobilePi Node.

---

## Node 本地持久化 — SQLite

Node 端使用 `sqlite3` 包（原生 FFI，非 sqflite）直接操作本地 SQLite 文件。

### 存储位置

- 默认路径：`~/.mobilepi/node.db`
- 可注入自定义路径（测试用临时目录）

### 表设计原则

**单记录表模式**：Node 只管理自身信息，使用 `CHECK (id = 1)` 强制单行。

```sql
CREATE TABLE IF NOT EXISTS node_info (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  node_id TEXT NOT NULL,
  hostname TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

### 初始化模式

```dart
class NodeDatabase {
  Future<Map<String, String>> initialize() async {
    // 1. 创建目录
    // 2. open DB
    // 3. CREATE TABLE IF NOT EXISTS
    // 4. SELECT → 存在则返回，不存在则 INSERT 新 UUID + hostname
    // 5. 返回 {'nodeId': ..., 'hostname': ...}
  }
}
```

**幂等性**：多次调用 `initialize()` 不产生副作用，始终返回同一 `nodeId`。

### 资源管理

- 必须调用 `close()` / `dispose()` 释放 `sqlite3.Database`
- NodeDaemon.stop() 中链式关闭：clients → server → db
