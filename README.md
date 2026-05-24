# MobilePi — 移动端多机 Coding Agent 调度编排系统

> **核心定位：指挥官看板，而非移动端 IDE。**
> 用户在脱离开发环境时，可通过手机/iPad 向分布在多台物理机上的 Coding Agent 下达指令、接收富媒体运行结果、并进行关键节点决策。

## 三端架构

| 端 | 路径 | 技术栈 | 核心职责 |
|---|---|---|---|
| **Client** | `client/` | Flutter | 控制台客户端（Android / iPad），只连接 Hub 获取已注册 Daemon、看板 UI、指令下发 |
| **Hub** | `hub/` | Dart CLI | 中枢转发服务器，维护内存级 Daemon 路由表 + 更新包 HTTP 宿主 |
| **Daemon** | `node/` | Dart AOT | 物理机守护进程，主动注册到 Hub，封装 Agent、会话扫描、截图回传、自动更新 |
| **Shared** | `shared/` | Dart Package | 三端共享的通信协议与数据模型 |

## 快速开始

### 1. 启动 Hub 中枢服务器
```bash
cd hub
dart pub get
dart run bin/hub.dart 8080
```

### 2. 启动 Daemon 守护进程（在目标物理机上）
```bash
cd node
dart pub get
dart run bin/node.dart ws://hub-server:8080/ws
```

### 3. 构建并运行 Client（Flutter）
```bash
cd client
flutter pub get
flutter run
```

## 核心约束

- **零代码编辑**：用户仅通过语义指令与上下文回滚纠偏 Agent。
- **Hub 不存储业务数据**：仅内存级 Daemon 路由表，会话日志与状态由 Daemon 端本地持久化。
- **Client 不管理 Daemon 接入**：Client 只能连接 Hub 并读取已注册 Daemon，不能新增 Daemon 或修改 Daemon 的连接方式。
- **富媒体解耦**：默认仅拉取图片 URL / 摘要，用户主动点击后才请求二进制大文件。
- **状态看板优先**：摒弃时间排序的 IM 列表，采用按 `Running / Waiting / Idle` 分类的任务看板。

## 技术栈

- **全栈 Dart**：Flutter (Client) + Dart CLI (Hub) + Dart AOT (Node)
- **通信**：WebSocket over TLS
- **Daemon 端存储**：SQLite + JSONL 会话日志扫描
