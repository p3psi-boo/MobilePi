# State Management

> Client (Flutter) state conventions for MobilePi.

---

## Provider + WebSocket 模式

Client 使用 `provider` 包管理全局 Hub WebSocket 连接与 Daemon/Node 状态。

### 架构

```
WebSocketService (Hub 连接数据层)
  ↓ Stream<MobilePiMessage>
NodeProvider (ChangeNotifier，业务层)
  ↓ notifyListeners()
DashboardScreen (Consumer<NodeProvider>，UI 层)
```

### 规则

1. **WebSocketService 不持有 UI 状态** — 只负责连接、心跳、消息收发，通过 Stream 向外暴露。
2. **NodeProvider 管理业务状态** — 解析 protocol `response.nodeSummary/nodeSummaries` 为 `NodeState`，维护 `Map<String, NodeState>`。
3. **UI 只读** — 通过 `Consumer`/`context.read` 消费状态，不下发连接指令（由 `initState` 触发 `connect()`）。

### NodeState 不可变性

```dart
@immutable
class NodeState {
  final String nodeId;
  final String hostname;
  final List<String> agents;
  final bool online;
  final DateTime? lastSeenAt;

  NodeState copyWith({...});  // 状态变更时生成新实例
}
```

### 连接生命周期

| 阶段 | 触发 | Provider 行为 |
|------|------|--------------|
| 启动 | `DashboardScreen.initState` → `postFrameCallback` → `connect()` | `_connecting = true` |
| 连接成功 | `_ws.connectionStream` 发射 `true` | `_connecting = false`，向 Hub 发送 protocol `hello(lastCursors)`，再对在线 Node 发送 `resume(cursors)` |
| 收到 node summary response | `_ws.messageStream` 发射 `response` | 解析 Hub/Node 返回的已注册 Daemon 摘要并更新 `_nodes`，`notifyListeners()` |
| 收到 protocol event `task.output.delta` | `_ws.messageStream` 发射 `event` | 若 `seq > local cursor`，追加到对应 `TaskState.streamingText`，更新 cursor，高频运行态更新用短 Timer 合并通知 |
| 断开 | `_ws.connectionStream` 发射 `false` | `_markAllOffline()` |
| 重连 | WebSocketService 指数退避后自动 `connect()` | 同上 |
| 下拉刷新 | `RefreshIndicator.onRefresh` → `refresh()` | 若在线重新发送 `hello/resume`，若离线触发 connect |

### Convention: Optimistic User Messages

**What**: Any composer action that sends user text to a running or historical
session must append a local `PiSessionMessageInfo(role: 'user', text: ...)` to
the owning `TaskState.messages` before sending the WebSocket command.

**Why**: The daemon may only acknowledge with a protocol event, or wait for
Pi/session history before returning `piMessages`. Without the optimistic
message, the chat appears to ignore the prompt until the backend catches up.

**Correct**:
```dart
_tasks[task.id] = task.copyWith(
  messages: [
    ...task.messages,
    PiSessionMessageInfo(role: 'user', text: prompt),
  ],
);
notifyListeners();
_ws.sendFollowUpCommand(task.nodeId, task.id, prompt);
```

**Wrong**:
```dart
_ws.sendFollowUpCommand(task.nodeId, task.id, prompt);
```

**Tests Required**: Provider tests for `sendFollowUp` and `sendSteer` must assert
that `TaskState.messages` contains the new user message before any daemon
response is emitted.

### 防坑

- **不要在 build() 期调用 connect()** — 必须在 `postFrameCallback` 或事件回调中触发，避免同步 setState。
- **_connecting 必须正确退出** — WebSocket 连接失败时 service 必须向 `connectionStream` 发射 `false`，否则 UI 卡死在 loading。
- **Client 不编辑 Daemon 接入** — 看板只能刷新 Hub 已注册 Daemon；不要在 UI 中提供添加 Daemon 或编辑 Daemon WebSocket URL 的入口。
- **流式输出不要逐 token notify** — `NodeProvider` 可以立即更新内存状态，但运行态 `streamingDelta` 应合并到约 80ms 一次通知，避免 Flutter Web 每个 delta 重建 Markdown。
- **协议事件必须按 cursor 去重** — `event.payload.streamId + event.payload.seq` 是 replay 去重边界。不要只依赖 `messageId`，因为 replay 后 transport id 可以变化。
- **历史 session 不要复制 transcript 到 streamingText** — 历史会话用 `messages` + 分页加载展示；把完整 transcript 同时放进 `streamingText` 会让详情页重复渲染并触发长帧。

## Node / Project / Session 层级

Client 的用户可见导航层级是：

```
Node(Machine)
  ↓
Project(Dir)
  ↓
Session
```

### 当前数据来源

1. **Node** 来自 WebSocket protocol `response.nodeSummary/nodeSummaries` 的 `NodeState`。
2. **Project** 目前由 `NodeProvider` 从 Node/Pi 状态与本地任务状态推导：优先使用 `piState.projectPath`、`projectDir`、`cwd`、`workingDirectory`、`workspace` 或嵌套 `project.path` / `project.dir`，否则使用该节点的默认 Project。
3. **Session** 由 `TaskState` 表达，必须携带 `projectId`、`projectPath` 和 `sessionId`，用于把最近任务、历史会话与 Project 详情页关联起来。历史 session 来自 `nodeSummary.piSessions`，Provider 负责把它们映射为只读的 `history` task，不在 UI 层伪造“已完成任务”。

### UI 合同

- Dashboard 顶层是单页纵向布局：上方展示已注册 Node，下方展示最近任务。
- 已注册 Node 使用横向 pill 列表；点击 Node 后进入该机器的 Project 列表。
- 最近任务展示跨节点的 session 列表，按更新时间倒序，并必须显示任务所属 Node（优先 `NodeState.hostname`，缺失时使用短 `nodeId`）。
- 点击 Project 后进入该 Project 的历史 Session 列表，并允许在该 Project 下新建 Session。

### 防坑

- 不要把当前派生 Project 当成后端真实目录枚举。后端协议提供明确 Project 列表后，应替换 `NodeProvider` 的推导逻辑，而不是在 UI 层硬编码假数据。
- 新建 Session 时必须把所选 `projectId` / `projectPath` 传入 Provider，避免任务创建后回落到节点默认 Project。
