# Mobile Multi-Agent Orchestration Dashboard — 移动端多机 Coding Agent 调度编排系统

## Goal

为开发者提供一个移动端（Android 手机 / iPad）的"指挥官看板"，在脱离开发环境（无电脑）时，可向分布在多台物理机（Mac/Linux）上的 Coding Agent（CodeX、PI Coding Agent）下达自然语言指令、接收富媒体运行结果（截图/URL）、并进行关键节点决策。**零代码编辑能力**——用户仅通过"语义指令"与"上下文回滚"对 Agent 纠偏。

全栈 Dart 语言（Flutter + Dart CLI Server + Dart AOT Node）。

## What I already know

来自 SPEC.md 的完整需求：

### 系统架构（三端分离，拉取式 + 极简中枢）

- **Client 端**：Flutter（Android 手机 + iPad），发起拉取请求、下达决策指令、渲染看板与对话流、呈现截图/预览
- **Hub 端**：云端 Dart CLI Server，仅做 WebSocket 透明转发 + HTTP File Server（Node 二进制更新包），不持久化业务数据，仅内存级设备路由表
- **Node 端**：Dart AOT 二进制（macOS/Linux ARM64 + x86_64），Agent 守护进程，负责调用本地 Agent CLI、扫描会话日志、持久化状态、截图、自动更新

### Client 端核心功能

1. **状态看板**：按 Running / Waiting / Idle 分类的任务列表，显示进度摘要
2. **快捷指令盘**：上下文感知的动态按钮（模糊搜索），禁止高频输入斜杠命令
3. **看门狗监控**：呼吸灯（绿/蓝 = 正常，黄 = 待决策，红 = 异常），一键 Panic Button 强制中断
4. **富媒体预览**：无代码 Diff，仅增删行数；支持截图、日志摘要、Web 预览 URL 内渲染

### Node 端核心功能

1. **环境持久化**：本地微型账本（JSON/SQLite），作为 Client 掉线的唯一数据源
2. **Agent 对接**：支持 CodeX 和 Pi，通过 Process.start 子进程调用
3. **会话管理**：扫描 `~/.codex/sessions/` 和 `~/.pi/agent/sessions/`，支持根据 Session_ID 恢复
4. **侧车式自动更新**：独立 Launcher 进程，版本比对 → 下载 → 替换 → 平滑重启 → 失败回滚

### Hub 端核心功能

1. TLS + WebSocket 长连接
2. 基于设备唯一 ID 路由（不解析 JSON Payload，版本更新协商除外）
3. 编译期挂载 Node 二进制文件到 HTTP 目录

### 多端布局

- **Android**：底部 Tab、下拉刷新、前台静默拉取
- **iPad**：Master-Detail 双栏，左栏机器列表/频道树，右栏对话流/预览/Webview
- **跨设备视觉隔离**：不同 Node 不同色调/图标，不同 Agent 不同气泡风格

### 鲁棒性约束

- 断网恢复后差量同步（last_msg_id）
- 错误处理只提供语义修正方案，严禁引导用户看代码
- 富媒体流与文本流解耦，默认只拉 URL/摘要，点击后按需加载大文件

## Assumptions (temporary)

- 仓库已有四包骨架（client/hub/node/shared），shared 协议和模型已定义
- Node 端不涉及 Agent 本身的开发——只做 wrapper/守护进程
- **MVP 阶段：Client + Node 直连，Hub 后置**
- 先做单平台（Android），iPad 先预留适配接口

## Open Questions

1. ~~MVP 范围：三端并行开发还是先聚焦某一端？~~ → **已定：Client + Node 直连，Hub 后置**
3. **Dart 项目结构**：monorepo（单一 git 仓库，三端共享 package）还是多 repo？→ **已是 monorepo，不变**
4. **Node 端持久化**：SQLite 还是 JSON 文件？→ **已定：SQLite**
5. **Agent 会话扫描**：CodeX 和 Pi 的会话目录结构长什么样？→ **Node 启动时扫描 PATH 中的 codex/pi 命令**
6. **身份认证**：Client-Node 之间的认证机制？→ **已定：MVP 跳过，局域网信任模型**
7. **首次 MVP 目标平台**：优先 Android 还是 iPad？→ **已定：Android 优先**
8. **自动更新的安全机制**：签名校验策略 → **MVP 不做（Hub 后置）**
9. **网络架构**：Hub 部署方案，NAT 穿透策略 → **MVP 不做（直连模式，Hub 后置）**

## Requirements (evolving)

### MVP — 第一铁轨：Client ↔ Node 直连 ✅ 已完成

- [x] Client 通过 WebSocket 直连 Node（硬编码 localhost:9000）并维持心跳（ping/pong）
- [x] Node 启动 WebSocket Server，启动时扫描 PATH 中的 codex/pi 命令
- [x] Node 响应 syncRequest：上报 nodeId、主机名、Agent 列表、状态
- [x] Client 看板展示在线 Node 列表（单台验证，数据模型支持多 Node）
- [x] Client 断线自动重连，心跳超时标记 Node 离线
- [x] Node 本地 SQLite 持久化自身信息（nodeId、hostname）

### MVP — 第二铁轨：Pi Agent 任务执行（进行中）

- [x] Client 发送自然语言指令（taskCommand）给 Node
- [x] Node 启动 `pi --mode rpc` 子进程，通过 stdin/stdout JSONL 控制
- [x] Node 将 Pi 的 stdout 事件流翻译为 taskUpdate 回传给 Client
- [x] Client 看板按 Running / Waiting / Idle 分类显示任务
- [x] Client Panic Button 发送 panic 消息，Node 强制终止 pi 进程
- [x] Node 本地 SQLite 持久化任务历史

**Agent 策略**：第二条铁轨只实现 Pi（`pi --mode rpc`），Codex 后置（需调研 CLI 调用方式）

### Acceptance Criteria

- [ ] Client 可与至少一台 Node 建立 WebSocket 连接并看到在线状态
- [ ] 断连后重连可恢复 Node 列表

## Definition of Done (team quality bar)

- Tests added/updated (unit/integration where appropriate)
- Lint / typecheck / CI green
- Docs/notes updated if behavior changes
- Rollout/rollback considered if risky

## Out of Scope (explicit)

- 代码编辑功能 — 系统定位是看板而非 IDE
- Agent 本身的功能开发 — 仅做 wrapper

## Technical Notes

- 文件路径：`/Users/bubu/remote-agent/SPEC.md` — 完整需求文档
- 技术栈约束：全栈 Dart（Flutter + Dart CLI Server + Dart AOT）
- Node 端需与本地 Agent CLI（codex, pi）交互

## Research References

- TBD
