# MobilePi 单人版长期同步架构设计

## 1. 结论

MobilePi 的长期架构应采用：

```text
WebSocket JSON
+ Node 本地 append-only event log
+ per-stream cursor replay
+ lightweight Hub relay
+ artifact 按需拉取
```

这个方案的核心判断是：单人使用不需要多人协同、复杂订阅系统或中心业务数据库，但仍然必须解决手机后台、弱网重连、长任务输出、历史恢复和大对象传输问题。

因此，系统边界应收敛为：

- **Node 是业务事实源**：任务、会话、事件日志、artifact 索引都由 Node 持久化。
- **Hub 是私有中继**：只负责 Node 反连、Client 连接、双向转发、在线状态和轻量鉴权。
- **Client 是投影视图**：本地状态可丢，靠 cursor 从 Node 恢复。
- **Agent CLI/RPC 是外部执行源**：Node 负责把 Pi/Codex 的原生事件转成 MobilePi 事件。

## 2. 背景与问题

当前 MVP 的 WebSocket 模型足够跑通端到端流程，但长期存在几个结构性问题：

1. 全量同步快照承担过重。节点能力、Pi state、messages、sessions 都可能塞进一个快照里，弱网和大历史下会变慢。
2. 非持久化实时事件断线后无法可靠补发。手机后台或 App 被杀时，live 输出会丢。
3. 输出目标绑定一次性的 `clientId`。Client 重连后生成新连接身份，旧任务事件可能无法继续送达。
4. 大文本和富媒体没有清晰分层。工具输出、截图、HTML、完整日志不应进入常规 WebSocket 事件。

单人版不需要多人订阅 fanout，但需要一个可靠的“断线恢复账本”。

## 3. 设计目标

### 3.1 必须支持

- 手机切后台、断网、App 被杀后重连。
- Node 上长任务继续运行，Client 回来后接上状态。
- 流式输出可增量显示，不需要全量刷新。
- 会话列表和消息历史分页加载。
- 截图、日志、HTML 预览、长 tool result 按需拉取。
- Hub 不持久化业务数据，运维成本低。
- 协议保持可调试，优先 JSON over WebSocket。

### 3.2 暂不支持

- 多用户、多租户、团队权限。
- 多 Client 同时活跃消费同一事件流。
- 协同编辑、CRDT、冲突合并。
- 中心化业务数据库。
- Kafka、NATS、RabbitMQ 等消息队列。
- 端到端加密的复杂密钥体系。

### 3.3 单人版约束

- 同一账号同一时间只允许一个活跃 Client。
- 新 Client 连接后可以顶掉旧 Client。
- Hub 只面向一个 owner token 或一组 owner devices。
- Node 是唯一长期 replay 源。

## 4. 总体架构

```text
┌──────────────────────────────┐
│ Client: Flutter mobile/tablet │
│ - UI materialized view        │
│ - cursor cache                │
│ - paged query cache           │
└───────────────▲──────────────┘
                │ WebSocket JSON
                │ hello/resume/command/event/query
┌───────────────┴──────────────┐
│ Hub: private relay            │
│ - auth                        │
│ - presence                    │
│ - Node route table            │
│ - one active Client           │
│ - optional short buffer       │
└───────────────▲──────────────┘
                │ WebSocket JSON
                │ register/forward/event
┌───────────────┴──────────────┐
│ Node: source of truth         │
│ - task runner                 │
│ - SQLite event log            │
│ - session index               │
│ - artifact store              │
│ - replay by cursor            │
└───────────────▲──────────────┘
                │ local RPC / process
┌───────────────┴──────────────┐
│ Agent: Pi / Codex             │
│ - native event stream         │
│ - session files               │
└──────────────────────────────┘
```

## 5. 状态所有权

| 数据 | 权威位置 | Hub 是否存储 | Client 是否持久化 |
| --- | --- | --- | --- |
| Node identity | Node SQLite | 否 | 缓存 |
| Node online status | Hub runtime + Node heartbeat | 内存 | 缓存 |
| Agent capabilities | Node | 否 | 缓存 |
| Task metadata | Node SQLite | 否 | 缓存 |
| Task live output | Node event log | 可选短缓冲 | 缓存投影 |
| Session index | Node 扫描/索引 | 否 | 分页缓存 |
| Transcript | Node / Agent session files | 否 | 分页缓存 |
| Artifact metadata | Node SQLite | 否 | 缓存 |
| Artifact bytes | Node filesystem | 否 | 按需下载 |
| Client cursor | Client 本地 + Node 可选记录 | 否 | 是 |

## 6. 核心概念

### 6.1 Stream

`streamId` 是可重放事件流的最小同步单位。

推荐命名：

```text
task:<taskId>
session:<sessionId>
node:<nodeId>
```

实际 MVP 可以先只实现 `task:<taskId>`。

### 6.2 Seq

每个 stream 内维护单调递增 `seq`：

```text
(streamId, seq) 唯一
```

要求：

- Node 生成 seq。
- Client 不生成 seq。
- 同一 stream 内按 seq 有序。
- 不保证不同 stream 之间全局有序。

### 6.3 Cursor

Cursor 表示 Client 已应用到哪个事件：

```json
{
  "task:abc": 42,
  "task:def": 8
}
```

Client 重连时把 cursor 发给 Node。Node 返回 `seq > cursor` 的事件。

### 6.4 Snapshot

Snapshot 是状态压缩点，不是常规同步手段。

使用场景：

- Client 首次打开。
- Client cursor 太旧，event log 已清理。
- 大量历史事件 replay 成本过高。
- Node schema 升级后需要重建投影视图。

## 7. 协议设计

### 7.1 Envelope

所有 WebSocket 消息使用统一 envelope：

```json
{
  "messageId": "uuid",
  "kind": "hello | resume | command | event | query | response | error",
  "from": "client | hub | node:<nodeId>",
  "to": "hub | node:<nodeId> | client",
  "protocolVersion": 1,
  "payload": {},
  "timestamp": "2026-05-20T12:00:00.000Z"
}
```

说明：

- `messageId` 用于请求响应和基础去重，不承担 replay cursor。
- `protocolVersion` 用于未来协议演进。
- 业务事件的顺序由 `payload.streamId + payload.seq` 表达。

### 7.2 Hello

Client 连接 Hub：

```json
{
  "kind": "hello",
  "from": "client",
  "to": "hub",
  "payload": {
    "clientId": "phone-main",
    "deviceName": "iPhone",
    "ownerToken": "redacted",
    "lastCursors": {
      "task:abc": 42
    }
  }
}
```

Hub 行为：

- 校验 owner token。
- 如果已有活跃 Client，关闭旧连接。
- 返回在线 Node 摘要。

### 7.3 Node Register

Node 连接 Hub 后注册：

```json
{
  "kind": "hello",
  "from": "node:<nodeId>",
  "to": "hub",
  "payload": {
    "nodeId": "node-1",
    "hostname": "macbook",
    "platform": "macos",
    "agents": ["pi"],
    "protocolVersion": 1
  }
}
```

Hub 只保存内存路由：

```text
nodeId -> websocket channel
```

### 7.4 Resume

Client 请求恢复：

```json
{
  "kind": "resume",
  "from": "client",
  "to": "node:node-1",
  "payload": {
    "cursors": {
      "task:abc": 42,
      "task:def": 8
    },
    "includeNodeSummary": true
  }
}
```

Node 返回：

```json
{
  "kind": "response",
  "from": "node:node-1",
  "to": "client",
  "payload": {
    "responseTo": "message-id",
    "nodeSummary": {},
    "events": [],
    "truncatedStreams": []
  }
}
```

如果某个 stream 的 cursor 已过期：

```json
{
  "streamId": "task:abc",
  "reason": "cursor_too_old",
  "snapshot": {}
}
```

### 7.5 Event

Node 推送任务事件：

```json
{
  "kind": "event",
  "from": "node:node-1",
  "to": "client",
  "payload": {
    "streamId": "task:abc",
    "seq": 43,
    "type": "task.output.delta",
    "taskId": "abc",
    "payload": {
      "text": "running tests\n"
    },
    "createdAt": "2026-05-20T12:00:00.000Z"
  }
}
```

Client 应用事件后更新本地 cursor：

```text
cursor["task:abc"] = 43
```

### 7.6 Ack

单人版 ACK 可以简化为低频游标上报：

```json
{
  "kind": "command",
  "from": "client",
  "to": "node:node-1",
  "payload": {
    "type": "cursor.ack",
    "cursors": {
      "task:abc": 43
    }
  }
}
```

用途：

- Node 可选记录最近 Client 消费位置。
- Hub 可选清理短期缓冲。
- 不是强一致提交协议。

Client 至少应在以下时机保存本地 cursor：

- 应用每批 replay 后。
- 每 1 秒批量落盘。
- App lifecycle pause/inactive。
- 任务完成。

### 7.7 Command

创建任务：

```json
{
  "kind": "command",
  "from": "client",
  "to": "node:node-1",
  "payload": {
    "type": "task.create",
    "requestId": "uuid",
    "taskId": "client-generated-or-empty",
    "agentType": "pi",
    "prompt": "run tests",
    "projectPath": "/Users/bubu/remote-agent",
    "model": "provider/model"
  }
}
```

Node 行为：

1. 幂等检查 `requestId`。
2. 创建 task。
3. 写入 `task.created` event。
4. 启动 runner。
5. 持续写入 output/status events。

追加指令：

```json
{
  "kind": "command",
  "payload": {
    "type": "task.follow_up",
    "requestId": "uuid",
    "taskId": "abc",
    "message": "continue"
  }
}
```

紧急停止：

```json
{
  "kind": "command",
  "payload": {
    "type": "task.panic",
    "requestId": "uuid",
    "taskId": "abc"
  }
}
```

### 7.8 Query

查询 Node 摘要：

```json
{
  "kind": "query",
  "payload": {
    "type": "node.summary"
  }
}
```

分页查询 sessions：

```json
{
  "kind": "query",
  "payload": {
    "type": "sessions.list",
    "projectPath": "/Users/bubu/remote-agent",
    "cursor": null,
    "limit": 30
  }
}
```

分页查询 messages：

```json
{
  "kind": "query",
  "payload": {
    "type": "messages.list",
    "sessionId": "pi-session-1",
    "before": 120,
    "limit": 30
  }
}

```

查询 artifacts：

```json
{
  "kind": "query",
  "payload": {
    "type": "artifacts.list",
    "taskId": "abc"
  }
}
```

## 8. 事件类型

### 8.1 Task events

| Type | Payload | 说明 |
| --- | --- | --- |
| `task.created` | `taskId, title, projectPath, agentType, model` | 任务创建 |
| `task.started` | `taskId, startedAt` | runner 已启动 |
| `task.status` | `taskId, status` | running/waiting/error/completed/idle |
| `task.output.delta` | `taskId, text` | 小块流式输出 |
| `task.output.snapshot` | `taskId, textRef or text` | 输出快照或压缩点 |
| `task.tool.started` | `taskId, toolCallId, toolName` | 工具开始 |
| `task.tool.finished` | `taskId, toolCallId, resultRef, isError` | 工具结束 |
| `task.progress` | `taskId, percent` | 进度 |
| `task.artifact.created` | `taskId, artifactId, kind` | 产物可用 |
| `task.decision.required` | `taskId, prompt, options` | 需要用户决策 |
| `task.completed` | `taskId, exitStatus` | 完成 |
| `task.aborted` | `taskId, reason` | 被停止 |
| `task.error` | `taskId, message, recoverable` | 错误 |

### 8.2 Node events

| Type | Payload | 说明 |
| --- | --- | --- |
| `node.summary` | `hostname, platform, agents, activeTasks` | 节点摘要 |
| `node.capabilities.changed` | `agents, models, commands` | 能力变化 |
| `node.heartbeat` | `time` | 心跳 |

## 9. Node SQLite 设计

### 9.1 `node_info`

```sql
CREATE TABLE node_info (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  node_id TEXT NOT NULL,
  hostname TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

### 9.2 `tasks`

```sql
CREATE TABLE tasks (
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
);
```

### 9.3 `events`

```sql
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  stream_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  ttl_policy TEXT NOT NULL DEFAULT 'normal',
  UNIQUE(stream_id, seq)
);

CREATE INDEX events_stream_seq_idx ON events(stream_id, seq);
CREATE INDEX events_created_at_idx ON events(created_at);
```

### 9.4 `stream_cursors`

```sql
CREATE TABLE stream_cursors (
  stream_id TEXT PRIMARY KEY,
  next_seq INTEGER NOT NULL
);
```

### 9.5 `command_requests`

```sql
CREATE TABLE command_requests (
  request_id TEXT PRIMARY KEY,
  command_type TEXT NOT NULL,
  task_id TEXT,
  result_json TEXT,
  created_at TEXT NOT NULL
);
```

用于 command 幂等，避免 Client 重试导致重复创建任务或重复追加指令。

### 9.6 `artifacts`

```sql
CREATE TABLE artifacts (
  artifact_id TEXT PRIMARY KEY,
  task_id TEXT,
  kind TEXT NOT NULL,
  content_type TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  local_path TEXT NOT NULL,
  sha256 TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX artifacts_task_idx ON artifacts(task_id);
```

## 10. Artifact 设计

WebSocket 事件只传 artifact metadata：

```json
{
  "artifactId": "art_123",
  "kind": "screenshot",
  "contentType": "image/png",
  "sizeBytes": 88213,
  "url": "/artifacts/art_123"
}
```

下载走 HTTP：

```text
GET /artifacts/:artifactId
Range: bytes=0-1023
```

推荐策略：

- 小于 32KB 的纯文本可以内联。
- 大于 32KB 的 tool result artifact 化。
- 截图、HTML、日志文件永远 artifact 化。
- artifact URL 由 Hub 反代到 Node，或 Client 经 Hub 请求 Node 返回临时 URL。

## 11. Hub 设计

### 11.1 职责

Hub 是私有中继，不是业务服务。

必须负责：

- WebSocket upgrade。
- owner token 鉴权。
- Node 注册。
- 一个活跃 Client 管理。
- Client 到 Node 的消息转发。
- Node 到 Client 的消息转发。
- online/offline presence。

可选负责：

- 最近 N 条消息短期缓冲。
- Ping/pong。
- 简单限流。
- artifact HTTP 反代。

### 11.2 内存状态

```text
activeClient: WebSocketChannel?
nodes: Map<nodeId, WebSocketChannel>
nodeSummaries: Map<nodeId, NodeSummary>
shortBuffers: Map<nodeId, RingBuffer<Message>>
```

单人版不需要：

- `clientId -> subscriptions`
- 多 client fanout
- 用户权限矩阵
- 业务事件持久化

### 11.3 连接规则

- 新 Client 连接成功后关闭旧 Client。
- Node 断开后标记 offline，Client 收到 presence update。
- Client 发给不存在的 Node，Hub 返回 route error。
- Node 未注册前发业务事件，Hub 丢弃并记录 warning。

## 12. Client 设计

### 12.1 本地状态

Client 本地维护：

```text
nodes
tasks
task output chunks
cursors
query cache
```

推荐 cursor 存储：

```json
{
  "node-1": {
    "task:abc": 43,
    "task:def": 8
  }
}
```

### 12.2 输出渲染

不要把所有 delta 不断拼接成单个无限增长字符串。

推荐：

```text
TaskOutputBuffer
  chunks: List<String>
  totalBytes: int
  compactedPrefix: String?
```

策略：

- 运行中按 50-100ms 合并 UI 通知。
- chunks 超过阈值后压缩旧段为 snapshot。
- Markdown 渲染只渲染可见范围或最近窗口。
- 详情页需要完整内容时再分页读取 transcript/artifact。

### 12.3 重连流程

```text
connect Hub
  -> hello(lastCursors)
  -> receive node summaries
  -> resume each online node
  -> apply replay events
  -> save updated cursors
```

如果收到 `truncatedStreams`：

```text
clear local projection for stream
apply snapshot
set cursor = snapshotSeq
```

## 13. Node 设计

### 13.1 Runner event pipeline

```text
Pi/Codex native event
  -> AgentRunner event
  -> MobilePi domain event
  -> SQLite append
  -> WebSocket flush queue
```

事件必须先写入 SQLite，再发送到 Client。

理由：

- 发送失败不丢事件。
- Client 重连可以 replay。
- Node crash 后仍可恢复到最后写入事件。

### 13.2 Flush 策略

Node 不应每个 token 立即发送。

推荐策略：

- 最多每 80ms flush 一批 output delta。
- 或累计 2-4KB flush。
- 状态变化、错误、完成事件立即 flush。
- tool result 大于阈值 artifact 化后发送 metadata。

### 13.3 Event log 清理

默认保留：

- running task：全部保留。
- completed task：保留最近 7-30 天事件。
- 大输出事件：可压缩为 snapshot + artifact。
- artifact：按大小和时间清理。

清理前必须保证：

- task summary 可重建。
- transcript 可通过 session files 或 artifact 查看。
- cursor 过期时能返回 snapshot。

## 14. 关键流程

### 14.1 创建任务

```text
Client -> Hub -> Node: task.create(requestId, prompt)
Node:
  insert command_requests
  create task
  append task.created seq=1
  append task.started seq=2
  start runner
  flush events
Client:
  apply events
  cursor[streamId] = latest seq
```

### 14.2 流式输出

```text
Runner emits text deltas
Node buffers 80ms
Node append event task.output.delta seq=N
Node sends event
Client appends chunk
Client saves cursor
```

### 14.3 Client 断线后恢复

```text
Client disconnected
Node keeps running
Node keeps appending events
Client reconnects with cursor
Node queries events where seq > cursor
Node sends replay batch
Client applies replay in seq order
```

### 14.4 Cursor 太旧

```text
Client cursor = 10
Node earliest retained seq = 80
Node returns snapshot at seq = 120
Client replaces local task projection
Client cursor = 120
```

### 14.5 Panic

```text
Client command task.panic(requestId, taskId)
Node append task.status(status=aborting)
Node abort runner
Node append task.aborted
Client applies final state
```

## 15. 错误处理

| 场景 | 处理 |
| --- | --- |
| JSON 解析失败 | 记录 warning，不关闭连接 |
| 未知协议版本 | 返回 protocol error |
| Node 不在线 | Hub 返回 route error |
| command requestId 重复 | 返回之前结果，不重复执行 |
| event replay 缺口 | 返回 snapshot/truncated |
| artifact 不存在 | 返回 404 + artifact_missing event 可选 |
| SQLite 写失败 | task.error，停止发送未持久化事件 |
| Runner crash | 写入 task.error + task.completed/aborted |

## 16. 安全模型

单人版先采用简单私有安全模型：

- Hub 强制 owner token。
- Node 连接 Hub 也带 node token。
- Hub 默认只暴露 WSS。
- Artifact 下载必须鉴权。
- Panic/command 类消息只接受 Client 来源。
- Node 不接受来自 Client 的任意 shell 命令，只接受白名单 command type。

后续可加：

- 设备配对码。
- token rotate。
- 每个 Node 独立 token。
- 审计日志。

## 17. 迁移计划

### Phase 1: Event log foundation

- 新增 Node SQLite `tasks/events/stream_cursors/command_requests/artifacts`。
- 实时输出发送前先写入 events。
- 引入 `streamId/seq/type`。
- Client 保存 per-stream cursor。

### Phase 2: Resume protocol

- 新增 `hello/resume/event/command/query` envelope。
- Node 支持按 cursor replay。
- Client 重连后使用 replay，不依赖全量同步快照。

### Phase 3: Remove old message families

- 线协议只保留 `hello/resume/command/event/query/response/error`。
- Hub hello 返回 node summaries。
- sessions/messages 改分页 query。
- 大 payload 从同步快照移除。

### Phase 4: Artifact plane

- Node artifact store。
- Hub 反代或转发 artifact HTTP。
- tool result/screenshot/log/html 改成 artifact metadata。

### Phase 5: Cleanup and hardening

- event compaction。
- retention policy。
- owner token/node token。
- route errors。
- crash recovery tests。

## 18. 验收标准

### 18.1 断线恢复

- Client 断开期间 Node 继续输出。
- Client 重连后能恢复断开期间的输出。
- 恢复后任务状态正确。

### 18.2 长输出性能

- 长任务输出不导致 WebSocket O(n²) 序列化。
- Flutter UI 不因逐 token notify 卡顿。
- 大 tool result 不进入普通 event payload。

### 18.3 查询分页

- sessions 列表分页。
- messages 分页。
- 首屏不加载完整 transcript。

### 18.4 Hub 简洁性

- Hub 重启会导致短暂断线，但业务历史不丢。
- Hub 不需要业务数据库。
- Node 重连后 Client 可重新 resume。

### 18.5 幂等命令

- Client command 超时重试不会创建重复任务。
- follow_up/panic 重试不会重复执行危险动作。

## 19. 设计取舍

### 为什么不让 Hub 持久化业务事件

单人版的长期维护成本比中心化便利性更重要。Hub 一旦持久化业务事件，就需要迁移、备份、清理、权限、数据一致性。Node 本来就靠近 Agent 和 session files，作为事实源更自然。

### 为什么不直接用 MQ

MQ 能解决投递，但不能自动解决业务 replay、snapshot、artifact、session 索引。对单人版来说，SQLite event log 更简单、可调试、部署成本低。

### 为什么还保留 JSON WebSocket

当前瓶颈不是 JSON 编码本身，而是全量同步、不可重放和大 payload 混入。先修语义，再换编码。等事件模型稳定后，可以把 event payload 换成 MessagePack 或 Protobuf。

### 为什么只允许一个活跃 Client

单人使用下，多活 Client 会引入订阅、ACK、冲突和视图一致性复杂度。一个活跃 Client 加 cursor replay 已覆盖手机/平板交替使用的大部分需求。

## 20. 最终目标

系统最终应表现为：

- Hub 可以随时重启，不丢业务历史。
- Client 可以随时断开，不丢任务进度。
- Node 可以独立运行长任务，并在 Client 回来后补齐状态。
- 首屏同步轻量。
- 长输出流畅。
- 大对象按需加载。
- 协议可用日志直接排查。

这就是单人版 MobilePi 在复杂度、性能和可靠性之间的最佳平衡点。
