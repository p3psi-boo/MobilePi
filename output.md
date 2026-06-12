# MobilePi 全面重构诊断与规划报告

> 基于对 client(~10k 行)/node/hub/shared 全部源码、SPEC.md、UI_IMPROVE.md、
> .trellis/spec 前端规范,以及 refs/howcode(Pi 桌面端参考实现)的逐文件分析。
> 所有结论均附 `file:line` 证据,可直接定位。

---

## 一、当前系统核心痛点与瓶颈诊断

### 1.1 性能与流畅度(掉帧根因)

按对帧率的影响排序:

**P-1【高】全局粗粒度 notifyListeners —— 每个流式 delta 重建半棵 Widget 树**
- `client/lib/providers/node_provider.dart` 是一个 1406 行的单体 ChangeNotifier,任何变化(节点摘要 :536、历史消息 :939、任务创建 :984、本地消息 :1043)都触发全局 `notifyListeners()`。
- 后果:Agent 每输出一段文本,Dashboard 任务列表、TaskStatusBar、详情页 AppBar 全部跟着 rebuild。这是 90/120Hz 目标下最致命的单点,帧预算只有 8.3ms,一次全树 diff 就能耗尽。
- 现有的 `Selector + shouldRebuild`(`dashboard_screen.dart:732`)只是补丁,且比较字段不全(漏 `createdAt` 等)。

**P-2【高】流式 Markdown 全量重解析,无任何缓存**
- `task_detail_screen.dart:912`:只有当文本超过 4000 字符(`_liveMarkdownPlainTextThreshold`)才降级为纯文本,4000 字符以内的流式消息**每个 delta 都对全文做一次完整 Markdown parse**(`pi_markdown.dart`,gpt_markdown 无 AST 缓存)。
- 已完成的历史消息在滚动时也会反复 parse —— 没有按内容 memo 的缓存层。
- `pi_markdown.dart:227` 附近每次 build 为代码块新建 ScrollController,无复用。

**P-3【中】节流管线不彻底**
- `node_provider.dart:1293-1304` 有 80/160/300ms 的流式合并通知,但只覆盖 `status == 'running' && streamingText != null` 这一条路径(:806);工具事件、状态变化、thinking 边界全部直接 `_notifyNow()`,工具密集型任务(Agent 的常态)下节流形同虚设。
- 间隔档位按 `textLength` 选择而非固定节拍,短消息阶段反而通知更频繁。

**P-4【中】滚动路径上的 setState 与列表配置**
- stick-to-bottom 状态机:`task_detail_screen.dart:328-345`,每次滚动方向反转都 `setState()` 重建整个 `CustomScrollView`,而它只想刷新一个"回到底部"按钮。
- 消息列表(`task_detail_screen.dart:531-598`)未关闭 `addAutomaticKeepAlives`,滚出屏幕的消息(含已 parse 的 Markdown 树)全部保活在内存;无 per-message `RepaintBoundary`。
- 卡片与 Composer 的 `BoxShadow(blurRadius: 18)` 在滚动时持续光栅化(UI_IMPROVE.md 第 5 条已自我诊断,未落地)。

**P-5【中】客户端零本地持久化 → 冷启动全量 replay**
- 客户端只在 SharedPreferences 存 cursors(`node_provider.dart:312-315`),消息、任务状态一概不存。每次启动/重连都要从 Node 重放事件、重拉历史,长会话场景下首屏既慢又抖。
- 对照 Pi 桌面端:`refs/howcode/desktop/thread-state-db.ts` 用 SQLite 持久化 thread 摘要 + 消息,首屏直接读本地,网络只做增量(`syncSessionSummaries(diffs)`)。

**P-6【低】其他**
- `streamingText` 每个 delta 做字符串拼接 + 超 24KB 时 `substring` 拷贝(`node_provider.dart:753`),长输出下 GC 压力大。
- `logs_screen.dart:102` 每次 build `.reversed.toList()`,LogBuffer 无上限。
- 未确认 Android 高刷模式:Flutter 在部分 Android 机型默认锁 60Hz,需要显式请求高刷新率;Impeller 状态也未显式声明。

### 1.2 UI/UX(极简视角下的冗余)

**U-1 视觉噪音超标**
- 状态/元信息全部用"满色底 + 边框"的 Pill(`_StatusPill`/`_MetaPill`),dashboard 单卡片嵌套 5 层 Container/Padding 且层层有 border/background(`dashboard_screen.dart:853-952`)。
- 状态色硬编码(`dashboard_screen.dart:837-843` 的 `0xFF4ADE80`/`0xFFFBBF24`),无 design token,暗色模式可读性靠运气。
- 用户气泡满色 primary、Agent 回复另一套 avatar+label 头部(`task_detail_screen.dart:1156-1175, 1309`),同一对话流两套视觉语言。

**U-2 交互层级过深**
- 回复 Agent(本产品最高频操作):首页 → 卡片 → 详情页 → 切 steer/follow-up → 选模型 → 输入发送,4-5 步;对标 Pi/Claude 移动端应为 2 步。
- 新建任务需先选 Node/项目再进入对话(`task_create_screen.dart`),与项目自己的规范矛盾 —— `.trellis/spec/frontend/component-guidelines.md` 明确要求 conversation-first("新建任务应直接打开空白对话")。

**U-3 移动端原生体验缺失**
- 核心操作(刷新、菜单、停止)集中在顶部 AppBar,Dashboard 顶部塞了 4 个交互元素 —— 全部在单手拇指热区之外。
- 手势体系几乎为零:无长按快捷菜单、无上滑面板;Dismissible 仅一处且方向与 iOS 习惯相反(`dashboard_screen.dart:775-819`)。
- 输入栏未系统处理 SafeArea/键盘 inset,小屏设备上 composer 占屏 20%+。

### 1.3 核心解析与时间线准确性(距 100% 的差距)

端到端链路:`Pi 进程(JSONL/RPC) → PiRunner 解析 → daemon 事件化 + SQLite → Hub 中转 → WebSocketService → NodeProvider 合并 → 渲染`。每一跳都有精度损失点:

**D-1【高】跨 stream replay 排序错误**
- `node/lib/persistence/node_db.dart:315-334` `eventsAfter()`:带 cursor 重连时,各 stream 独立查询后按 **streamId 字典序** 排序再 `take(limit)` 截断。两个后果:
  1. 重放顺序不反映真实时间线(任务 B 先发生的事件可能排在任务 A 之后);
  2. 截断丢弃的永远是字典序靠后的 stream,且无 `hasMore` 标志,client 无从感知。

**D-2【高】cursor 过期无 snapshot 兜底**
- 设计文档(single-user-sync-design.md)和 SPEC 都定义了 `truncatedStreams` + snapshot 恢复,但代码中 `truncatedStreams` 恒为空(daemon.dart:485-517 无实现)。一旦启用事件清理(`node_db.dart:388` purgeOldEvents),持有旧 cursor 的 client 将**永远收不到该 stream 的任何事件**,且无报错。

**D-3【高】去重键不一致**
- 项目自己的规范(`.trellis/spec/frontend/state-management.md`)要求按 `(streamId, seq)` 去重,但 client 实际按 transport 层 `messageId` 去重(`websocket_service.dart:215-231`)。replay 时 messageId 会变,同一事件可能被应用两次。
- 历史消息合并的 `_messageDedupKey()`(`node_provider.dart:884-890`)用 parts 结构签名拼凑,启发式易误判。

**D-4【中】Pi 输出解析的信息丢失**
- `node/lib/agent/pi_session_index.dart:387`:session JSONL 中的 **toolCall 块被刻意丢弃**,只靠 toolResult 反推 —— 工具入参丢失,result 缺失/乱序时历史不完整。
- client 端 `toolEvents` 列表与消息 `parts` 中的 toolCall/toolResult 是两套并行表达(`node_state.dart:22-41` + provider 两处拼装),无 single source of truth。
- `streamingText` 与 `streamingParts` 双轨并存,渲染层要走两套分支(`task_detail_screen.dart:620-708`)。

**D-5【中】解析层健壮性**
- `pi_rpc_client.dart:335-359`:`jsonDecode(line)` 无 try-catch,一行损坏 JSON 会让整个 RPC 流进入错误路径。
- session 文件 tail-follow(`daemon.dart:1110-1147`):字节读取后先 `utf8.decode(allowMalformed: true)` 再拼 partial —— 读取边界落在多字节字符中间时,中文会变 U+FFFD 且**不可恢复**(partial 是已损坏的字符串)。正确做法是在字节层保留 partial。
- 同文件 :1129-1135:tail 去重用 `delta.hashCode` + 300 行滑动窗口,哈希碰撞 → 丢消息,窗口滑出 → 幻影重复。

**D-6【中】24KB 流式截断丢前文**
- `node_provider.dart:16,753`:streamingText 超 24KB 静默丢弃前文,且消息落盘前 client 无法找回 —— 长输出任务在进行中阶段必然展示不完整。

### 1.4 网络层韧性(影响"丝滑感"的隐性因素)

- **断网即丢**:daemon 发送失败仅 log warning,无缓冲重发(`daemon.dart:1703-1713`);Hub 纯透传无短期缓冲(`hub/lib/server.dart:347`)。好在 Node 端 SQLite 是事实源,但 client 必须依赖 resume 补齐 —— 而 resume 又踩 D-1/D-2 的坑。
- **半开连接感知慢**:心跳 30s × 3 次 pong 容忍 = 最坏 90s 才发现假连接(`websocket_service.dart:244-258`),移动网络切换场景下体感是"卡死一分半"。
- **N 倍序列化**:daemon 对每个订阅者独立 `jsonEncode + send`(`daemon.dart:1638-1654`);单用户场景影响小,但属白白浪费。
- 订正一处误判风险:`node_db.dart:421` 的 `'taskId': ?taskId` 是 Dart 3.8+ null-aware element 合法语法(SDK ^3.11.4),**不是 bug**,重构时勿"顺手修复"。

---

## 二、客户端重构愿景与 UI/UX 重新设计方案

### 2.1 设计原则

产品定位是"指挥官看板"(SPEC.md):用户在通勤路上单手握机,90% 的操作是 **瞥一眼状态 → 批准/纠偏 → 收起手机**。界面应当为这条 10 秒动线设计,其余一切让路。

三条铁律:
1. **两层结构封顶**:Home(任务流)→ Conversation(对话),不存在第三层常驻页面;其余功能(日志、设置、节点管理)全部降级为 sheet/drawer。
2. **拇指优先**:所有高频操作落在屏幕下半部;顶部只放不可点的信息。
3. **一种视觉语言**:删掉 Pill 边框、满色气泡、多层卡片;状态只用"一个色点 + 字重",层级靠留白和字号,不靠框线。

### 2.2 Home:统一任务流(替代现 Dashboard + Kanban 双页)

```
┌──────────────────────────────┐
│  MobilePi            ● 已连接 │   ← 纯信息,不可点,极小
│                              │
│  需要决策                     │   ← Waiting 永远置顶
│  ● fix-auth-bug    刚刚       │     色点=状态灯(红黄绿)
│    "是否回退到上一提交?"        │     一句话上下文
│    [回退] [换思路] [查看]      │   ← 决策按钮直接内联,免进详情页
│                              │
│  运行中                       │
│  ● refactor-ui     3m  ▂▄▆   │     微型进度,无卡片边框
│  ● write-tests     12m ▂▂▄   │
│                              │
│  最近完成                     │
│  ○ deploy-docs     2h        │
│                              │
│         ［ ＋ 新任务 ］        │   ← 底部大靶区,拇指热区
└──────────────────────────────┘
```

- **Waiting 任务的 Action Palette 直接内联在 Home 卡片上** —— 最高频决策 1 步完成,这是对"指挥官"定位最大的体验杠杆。
- 三态分组(Running/Waiting/Idle)保留 SPEC 设计,但组内按时间线排序;去掉独立 Kanban 页。
- 节点离线等异常以分组顶部一行细字提示,不弹窗、不占卡片。

### 2.3 Conversation:对齐 Pi 桌面端的对话流

- **Composer 一级地位**(对齐 howcode):常驻底部;steer/follow-up 不再是模式切换 —— Agent 运行中发送即 steer,空闲时发送即 follow-up,系统自动判断,用一行小字提示当前语义。模型选择收进 composer 左侧一个低调入口(bottom sheet)。
- **消息流视觉**:用户消息右对齐细边色块(唯一保留的"气泡"),Agent 输出无气泡、无头像,直接排版 —— 阅读密度提升一倍,这正是 Pi/Claude 桌面端的做法。
- **工具调用渲染为单行折叠条**:`▸ Edit main.dart +12 -3`,点按展开 result;连续工具调用聚合为一个组(现有 turn collapsing 方向正确,保留并强化)。
- thinking 块默认折叠为一行 `▸ 思考了 8s`。
- **Waiting 状态时,Action Palette 出现在 composer 上方**,替代(而非叠加)其他 UI。

### 2.4 手势体系

| 手势 | 行为 |
|---|---|
| 任务卡片长按 | bottom sheet:停止 / 置顶 / 查看日志 / 删除(替代 Dismissible 误触) |
| 详情页右滑边缘 | 返回 Home(iOS 原生感) |
| 详情页底部上滑把手 | 拉出日志/截图 drawer(替代独立 logs 页) |
| 任务流下拉 | 刷新 + 强制重连(顺手解决"假连接"的手动恢复) |
| 流式输出区上滑 | 立即脱离 stick-to-bottom;"↓ 回到底部"按钮浮现在 composer 上方右侧拇指区 |

### 2.5 视觉系统(design tokens)

- 一个中性灰阶 + 一个 accent 色 + 红黄绿三个状态色,全部进 `ThemeExtension`,删除所有硬编码 `Color(0xFF...)`。
- 阴影全删,层级用 `surfaceContainerLow/High` 色阶表达;圆角统一 2 档;字号 4 档。
- 点击靶区全面 ≥ 44pt;状态 Pill 改为"色点 + 文字",零边框零底色。

---

## 三、核心技术重构方案 (Technical Implementation)

### 3.1 状态层:从单体 ChangeNotifier 到分域细粒度通知

不引入新框架(hobby 项目克制原则,Provider 留作依赖注入),把 NodeProvider 拆为四个独立可测单元:

```
WebSocketService (传输,纯 Stream)
   ↓
SyncEngine        ← 协议事实:去重((streamId,seq))、cursor、resume、排序合并
   ↓ 写入
TaskStore         ← Map<taskId, TaskNotifier>;TaskNotifier extends ValueNotifier<TaskState>
NodeRegistry      ← ValueNotifier<List<NodeState>>(节点列表,低频)
SessionCache      ← drift/SQLite 本地缓存(消息、任务快照)
```

关键点:
- **每个任务一个 `TaskNotifier`**。详情页用 `ValueListenableBuilder` 只订阅当前任务;Home 列表订阅 TaskStore 的"结构变化"信号(增删/状态迁移),流式 delta 不再波及列表。这一刀下去,P-1 即解。
- 流式文本进一步拆出 `ValueNotifier<StreamingBuffer>`,只有正在流式的那一个 part 的 widget 订阅它 —— 每个 delta 的重建范围收敛到单个文本块。
- **节流改为固定节拍**:delta 到达只写 buffer,由一个 80ms 周期(或 `Ticker` 对齐 vsync)统一 flush 到 notifier;工具事件、状态变化走同一管线,消灭 P-3 的旁路。

### 3.2 渲染层:90/120Hz 的具体手段

1. **Markdown 三态渲染**(对齐 howcode 的 streaming buffer 模式):
   - 流式中:当前增长中的 part 一律纯 `Text`(廉价),不论长短 —— 4000 字符阈值取消;
   - part 封口(thinking 边界/工具调用切断/消息完成)时:升级为一次性 Markdown parse;
   - 已完成消息:`PiMarkdown` 外包 `RepaintBoundary`,并按 `content.hashCode` 做 widget 级 memo 缓存,滚动时零重解析。
2. **消息列表**:`SliverList` 保留,`addAutomaticKeepAlives: false` + 每条消息 `RepaintBoundary`;stick-to-bottom 的按钮显隐改为独立 `ValueNotifier<bool>`,滚动回调不再 setState 整页。
3. **本地缓存优先的首屏**:进入对话先渲染 SessionCache 中的快照(同步、零网络),resume 增量到达后原位补齐 —— 冷启动从"白屏转圈"变为"瞬时出内容"。
4. **平台层**:Android 上用 `flutter_displaymode` 请求高刷模式(多数国产 ROM 默认锁 60);确认 Impeller 开启;首次进入对话页前预热常用 shader 路径。
5. 删 `blurRadius:18` 阴影、补 `prefer_const_constructors` lint 并清零警告(UI_IMPROVE.md 第 4/5 条直接落地)。

### 3.3 解析层:100% 准确率的协议加固(Node 端)

1. **字节级行缓冲**:tail-follow 的 partial 保留在 `List<int>` 字节层,凑齐完整行后再 `utf8.decode`(strict 模式)→ 根除多字节截断(D-5)。
2. **单行容错**:每行独立 `try { jsonDecode } catch { 记数 + 落日志, continue }`,坏行不掐断流。
3. **无损 parts 模型**:session 解析保留全部块 —— text / thinking / toolCall(含入参) / toolResult(按 id 配对),`MessagePart` 升级为 sealed class;**删除 `toolEvents` 与 `streamingText` 双轨**,渲染层只认 parts,一处事实源(对齐 howcode 的 MessagePart 设计与项目自身 state-management.md 规范)。
4. **确定性去重**:tail 去重键改为 `(sessionPath, byteOffset)`(读到哪算哪,天然单调),弃用 hashCode 指纹。
5. **流式不截断**:取消 client 端 24KB substring;长文本靠"part 封口即转存 SessionCache + 只保留活跃 part 在内存"解决内存压力,而不是丢数据。

### 3.4 时间线:全局有序的同步协议(Node + Client)

1. **replay 按全局序**:`eventsAfter()` 改为单条 SQL —— 利用已有的全局自增 `id`:
   ```sql
   SELECT * FROM events e
   WHERE e.seq > COALESCE(:cursor_of(e.stream_id), -1)
   ORDER BY e.id    -- 全局插入序 = 真实时间线
   LIMIT :limit
   ```
   (实现上用临时表/json 参数传 cursors,或在 Dart 侧按 `id` 归并排序);响应增加 `hasMore: true`,client 循环拉取直到追平。
2. **实现 truncatedStreams + snapshot**:cursor 早于已清理事件时,返回该 stream 当前任务快照 + 新 cursor,client 以快照重建后继续增量 —— 补上 D-2 这个未来必踩的坑。
3. **统一去重键**:client 删除 messageId 去重,一律 `(streamId, seq)`;`seq <= cursor` 直接丢弃,等于幂等回放。
4. **client 时间线合并算法**:历史分页、实时事件、本地乐观消息三路统一进一个按 `(timestamp, streamId, seq)` 排序的有序结构(乐观消息以临时 seq 占位,服务端确认后原位替换),消灭 `_messageDedupKey` 启发式。
5. 心跳收紧:间隔 15s、2 次容忍,前台恢复时主动 ping 一次 —— 假连接感知从 90s 降到 ~30s,配合下拉刷新手势兜底。

### 3.5 技术选型小结

| 事项 | 选择 | 理由 |
|---|---|---|
| 状态管理 | Provider(注入)+ ValueNotifier(细粒度) | 不换框架,改通知拓扑;迁移成本最低 |
| 本地缓存 | drift(SQLite) | 与 Node 端 sqlite3 心智一致,对齐 howcode 的 thread-state-db |
| Markdown | 保留 gpt_markdown + 外层 memo/RepaintBoundary | 问题在调用方式不在库 |
| 高刷 | flutter_displaymode + Impeller | Android 解锁高刷的事实标准 |
| 协议 | 不换 WebSocket/JSON,只补 hasMore/truncatedStreams/snapshot | 安全边界与开发效率优先(指标 5) |

---

## 四、逐步实施计划 (Step-by-Step PLAN)

> 排序逻辑:先保证"数据 100% 正确"(地基),再改状态层(承重墙),最后动 UI 与性能打磨(装修)。每阶段可独立合入、独立回滚。

### Phase 0 — 基线与防回归(0.5 周)【P0,先行】
1. 解析 golden tests:收集真实 Pi session JSONL(含中文、长输出、工具嵌套、损坏行)作为 fixture,锁定 node 端解析输出。
2. 同步协议集成测试:断线重连、cursor 回放、多任务并发的端到端用例(现有 node/test 基础上扩)。
3. 性能基线:DevTools timeline 录制"流式输出中的详情页"与"任务列表滚动",记录 raster/build 耗时作对照组。
- **验收**:CI 跑通全部 golden;有可对比的帧耗时数据。

### Phase 1 — 解析与时间线正确性(1–1.5 周)【P0,最高优先级】
对应 §3.3、§3.4,全部在 node/shared/同步层,不碰 UI:
1. 字节级行缓冲 + strict UTF-8 + 单行 try-catch(D-5)。
2. byteOffset 去重替换 hashCode(D-5)。
3. 无损 parts:保留 toolCall 入参、sealed MessagePart、删双轨表达(D-4)。
4. `eventsAfter` 全局序 + `hasMore`(D-1)。
5. `truncatedStreams` + snapshot 恢复(D-2)。
6. client 统一 `(streamId, seq)` 去重(D-3);取消 24KB 截断(D-6)。
- **验收**:golden 全绿;任意断点 kill client/hub 后重连,消息序列与 Node 端 SQLite 逐条一致、无重复无丢失。

### Phase 2 — 状态层重构与本地缓存(1.5 周)【P1】
对应 §3.1:
1. NodeProvider 拆分为 SyncEngine / TaskStore(per-task ValueNotifier)/ NodeRegistry;UI 改订阅方式,行为不变。
2. 固定节拍流式 flush 管线(工具事件并入)。
3. 引入 drift SessionCache:消息与任务快照落地,冷启动先本地后增量。
4. 心跳收紧 + 前台主动 ping。
- **验收**:流式输出时 Home 列表零 rebuild(DevTools 验证);飞行模式开关 app,历史立即可见;Phase 0 基线 build 耗时下降 ≥50%。

### Phase 3 — 移动端 UI 极简重构(1.5–2 周)【P1】
对应 §二:
1. design tokens(ThemeExtension)落地,清除硬编码色/阴影/Pill 边框。
2. Home 统一任务流:三态分组 + Waiting 决策按钮内联;删除独立 Kanban 页。
3. Conversation 重排:无气泡 Agent 输出、工具折叠条、thinking 折叠、composer 自动 steer/follow-up 语义。
4. 手势体系:长按 sheet、边缘右滑返回、上滑日志 drawer、下拉刷新重连。
5. conversation-first 建任务(进对话再补 Node/项目选择,落实自家 component-guidelines)。
- **验收**:回复 Waiting 任务 1 步、新建任务 2 步;所有高频操作位于屏幕下半部;无任何 `Color(0xFF...)` 散落。

### Phase 4 — 性能压榨与体验对齐(1 周,持续)【P2】
对应 §3.2 与指标 5:
1. Markdown 三态渲染 + memo 缓存 + RepaintBoundary。
2. stick-to-bottom 按钮独立 notifier;列表 keepAlive 关闭。
3. flutter_displaymode 高刷 + Impeller 确认 + shader 预热。
4. 体验对齐细节:工具组折叠动效、流式光标、乐观消息即时上屏、打断(steer)的瞬时反馈 —— 对标 Pi 桌面端的"零等待感"。
5. 复测 Phase 0 基线:目标流式输出中 99% 帧 raster+build < 8.3ms(120Hz 预算)。
- **验收**:真机(高刷 Android + iPad)录屏无可感知掉帧;DevTools 无超预算帧尖刺。

### 暂不做(刻意收缩,符合指标 5)
- Hub 消息缓冲/多用户路由治理 —— 单用户场景下 Node 事实源 + 修复后的 resume 已覆盖;
- 鉴权/TLS 加固、Artifact 版本管理、undo/redo —— 超出 hobby 项目当前收益曲线;
- daemon 端 N 倍序列化优化 —— 单订阅者下无收益,留待真有多端需求时再做。

---

### 附:致命问题 Top 5 速查

| # | 问题 | 位置 | 解决于 |
|---|---|---|---|
| 1 | 单体 Provider 全局通知,流式 delta 重建半棵树 | node_provider.dart:536,939,984 | Phase 2 |
| 2 | 流式 Markdown 每 delta 全量重解析、零缓存 | task_detail_screen.dart:912 | Phase 4 |
| 3 | 跨 stream replay 按字典序排序+静默截断 | node_db.dart:315-334 | Phase 1 |
| 4 | cursor 过期无 snapshot,client 永久失联 | daemon.dart:485-517 | Phase 1 |
| 5 | toolCall 丢弃 + 双轨消息表达,历史不完整 | pi_session_index.dart:387 | Phase 1 |
