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
    ↓ notifyListeners() / taskListenable(taskId)
DashboardScreen / TaskDetailScreen (UI 层)
```

### 规则

1. **WebSocketService 不持有 UI 状态** — 只负责连接、心跳、消息收发，通过 Stream 向外暴露。
2. **NodeProvider 管理业务状态** — 解析 protocol `response.nodeSummary/nodeSummaries` 为 `NodeState`，维护 `Map<String, NodeState>`。
3. **Task 详情订阅单个任务** — 高频任务详情组件优先使用 `NodeProvider.taskListenable(taskId)`，只在目标 `TaskState` 写入或删除时重建；不要用全局 `Consumer<NodeProvider>` 订阅整张 `_tasks`。
4. **UI 只读** — 通过 `Consumer`/`Selector`/`ValueListenableBuilder`/`context.read` 消费状态，不下发连接指令（由 `initState` 触发 `connect()`）。

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
| 下拉刷新 | `RefreshIndicator.onRefresh` → `refresh()` | 若在线调用 `forceReconnect()` 重建 socket，重连成功后发送 `hello/resume`；若离线触发 connect |

### Convention: Optimistic User Messages

**What**: Any composer action that sends user text to a running or historical
session must append a local `PiSessionMessageInfo(role: 'user', text: ...)` to
the owning `TaskState.messages` before sending the WebSocket command.

**Why**: The daemon may only acknowledge with a protocol event, or wait for
Pi/session history before returning `piMessages`. Without the optimistic
message, the chat appears to ignore the prompt until the backend catches up.

**Correct**:
```dart
_setTask(task.copyWith(
  messages: [
    ...task.messages,
    PiSessionMessageInfo(role: 'user', text: prompt),
  ],
));
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
- **流式输出不要逐 token notify** — `NodeProvider` 可以立即更新内存状态，但运行态 `streamingDelta` / `toolCall` / `toolResult` / `thinking` / `statusLabel` 应走同一条固定约 80ms 的合并通知节拍，并且只刷新对应 `taskListenable(taskId)`；不要为流式 delta 触发全局 `notifyListeners()`，避免移动端每个 delta 反复重建/解析大段 Markdown。
- **Replay 流式事件要登记待刷新 task** — `resume/hello` 批量应用历史事件时可以 `notify: false`，但被合并的流式 task id 必须加入待刷新集合，等外层 `_notifyNow()` 一次性 flush `taskListenable`；否则详情页会在同步后继续显示旧 `TaskState`。
- **TaskState 写入必须走 `_setTask`，删除必须走 `_removeTaskState`** — 这两个 helper 同步 `_tasks` 和 `taskListenable(taskId)`，避免详情页拿到过期状态或删除后继续显示旧任务。
- **详情页不要用全局 task selector 兜底** — AppBar、状态栏、流式输出等任务局部 UI 应从 `taskListenable(taskId)` 获取 `TaskState`；只把 Node 或连接状态等跨任务数据留给 `Selector<NodeProvider, ...>`。
- **Dashboard 最近任务列表使用结构 notifier** — 首页最近任务流订阅 `recentTasksListenable`，Provider 内部只在 id/status/progress/title/node/project/model/createdAt 等卡片可见字段变化时刷新；不要在 UI 层每次全局 notify 后重新 sort/比较 `_tasks`。
- **状态层不要截断 streamingText / streamingParts** — 长输出可以在渲染层限制可见窗口，但 `TaskState` 必须保留完整已收到内容；否则运行中长任务会静默丢前文，最终消息落盘前无法恢复。
- **协议事件必须按 cursor 去重** — `event.payload.streamId + event.payload.seq` 是 replay 去重边界。不要只依赖 `messageId`，因为 replay 后 transport id 可以变化。
- **历史 session 分页按 `sourceIndex` 去重** — 新的 `PiSessionMessageInfo` 必须携带会话源序号，Provider 合并分页时优先按 `sourceIndex` 判断重复；role/text/parts 内容签名只用于兼容没有源序号的旧缓存或预览消息。
- **历史 session 不要复制 transcript 到 streamingText** — 历史会话用 `messages` + 分页加载展示；把完整 transcript 同时放进 `streamingText` 会让详情页重复渲染并触发长帧。
- **SessionCache 只做冷启动快照，不取代协议事实源** — `SessionCache` 使用 drift/SQLite 保存最近 `TaskState` 快照与消息窗口；`NodeProvider.loadSettings()` 可以先 hydrate 缓存让首页/会话瞬时可见，但连接成功后的 `hello/resume` 仍是权威增量来源。缓存写入必须 debounce，避免流式 delta 每帧落盘；缓存失败不得阻塞 live sync。
- **SessionCache 依赖必须可测试** — 当前测试环境不提供 macOS SDK native-assets 编译链，避免通过 `path_provider_foundation` 等依赖把 `objective_c` hook 拉进普通 unit tests。缓存路径优先使用 `MOBILEPI_SESSION_CACHE_DIR`，再退到 `$HOME/.mobilepi` / system temp。

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
