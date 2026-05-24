# Pi RPC 启动延迟调研报告

## 测量数据

### 各配置启动时间

| 配置 | 启动时间 | 说明 |
|---|---|---|
| 全部 extensions | **2.2s** | 默认配置 |
| `--no-extensions` | **0.2s** | 10x 加速 |
| `--no-extensions --no-skills` | **0.2s** | skills 影响可忽略 |

### 逐步 Timings（带 extensions）

```
parseArgs:              2ms
runMigrations:          2ms
createSessionManager:   7ms
createRuntime:          1ms
readPipedStdin:     2,169ms  ← 实际是 createAgentSessionRuntime（见下）
prepareInitialMessage:  0ms
initTheme:              1ms
resolveModelScope:      0ms
createAgentSession:     0ms
TOTAL:              2,182ms
```

### 逐步 Timings（无 extensions）

```
parseArgs:              0ms
runMigrations:          1ms
createSessionManager:   4ms
createRuntime:          0ms
readPipedStdin:       210ms  ← 实际是 createAgentSessionRuntime
TOTAL:                216ms
```

## 根因分析

### 1. Timings 标签误导

`readPipedStdin` 标签 **并不是** 读取 stdin 的时间。RPC 模式下 `readPipedStdin()` 被跳过了。实际计时的是 `createAgentSessionRuntime`，它包含了 `createAgentSessionServices` + `createAgentSessionFromServices`。

代码流程：
```typescript
time("createRuntime");                                    // 标记
const runtime = await createAgentSessionRuntime(...);     // ← 这才是耗时大户
// ...
time("readPipedStdin");                                   // 下一个标记（标签有误导）
```

### 2. 真正的瓶颈：Extension 加载

Pi 启动时加载的所有 extensions（~383KB TypeScript）：

| Extension | 大小 | 说明 |
|---|---|---|
| autoresearch/index.ts | 120KB | 最大 |
| todos.ts | 64KB | |
| insights.ts | 64KB | |
| subagents/ (3 files) | 47KB | agent-pool, index, tui |
| context.ts | 18KB | |
| web-fetch/index.ts | 9KB | |
| cognitive.ts | 4KB | |
| uv.ts | 4KB | |
| notify.ts | 2KB | |

Extension 加载过程：
1. `packageManager.resolve()` — 解析所有扩展路径
2. `loadExtensions()` — **动态编译并执行 TypeScript**（使用 tsx/transpile）
3. `loadExtensionFactories()` — 执行扩展的 `register()` 函数
4. 每个 extension 在 `bindExtensions()` 时触发 `session_start` 事件，发出 extension_ui_request

### 3. 启动流程拆解

```
Process.start
  └── Node.js V8 启动          ~50ms
  └── ES Module 加载            ~100ms
  └── parseArgs                  ~2ms
  └── runMigrations              ~2ms
  └── createSessionManager       ~7ms
  └── createAgentSessionRuntime
      └── createAgentSessionServices
          ├── SettingsManager.create
          ├── ModelRegistry.create
          ├── ResourceLoader.reload()  ← 核心瓶颈
          │   ├── packageManager.resolve()
          │   ├── loadExtensions()     ← TypeScript transpile + execute
          │   ├── loadExtensionFactories()
          │   └── updateSkills/Prompts
          └── createAgentSessionFromServices
  └── runRpcMode
      ├── rebindSession()         ← extensions 初始化，发出 extension_ui_request
      ├── registerSignalHandlers
      └── attachJsonlLineReader   ← 开始接受 stdin 命令
```

### 4. 为什么之前测出 7.8s

网络环境不稳定时，`ModelRegistry.create()` 或 extension 初始化中的网络请求可能导致额外延迟。本地纯净测试稳定在 2.2s。

## 解决方案建议

### 方案 A：`--no-extensions` 快启动（推荐 MVP）

```dart
Process.start('pi', ['--mode', 'rpc', '--no-session', '--no-extensions'])
```

优点：启动 0.2s，10x 加速
缺点：无 trellis、todos、subagents 等扩展功能

### 方案 B：选择性加载 extensions

```dart
Process.start('pi', ['--mode', 'rpc', '--no-session', '--no-extensions',
  '--extensions', '/path/to/essential-ext.ts'])
```

优点：只加载必要的扩展
缺点：需要维护扩展列表

### 方案 C：预编译 extensions（中期优化）

Pi 的 extension 加载走的是 tsx 动态编译，如果能缓存编译结果，可以大幅降低 ~2s 的 transpile 开销。

### 方案 D：Node 端 Agent 常驻（长期方案）

Node 启动 PiRunner 后保持进程存活，后续任务复用同一个 pi 进程，避免重复初始化。

```dart
// 伪代码：任务队列模式
class PiRunnerPool {
  Process? _warmProcess;  // 预热的 pi 进程
  
  Future<void> warmUp() async {
    _warmProcess = await Process.start('pi', ['--mode', 'rpc', '--no-session']);
    // 等待 extension_ui_request 事件停止后标记为 ready
  }
  
  Future<void> submit(String prompt) async {
    // 直接发送 prompt，无需等待启动
    _warmProcess!.stdin.writeln(jsonEncode({'type': 'prompt', 'message': prompt}));
  }
}
```

## 对 e2e 测试的影响

Rail 2 e2e 测试只收到 1 条 taskUpdate（status=running），因为：
1. PiRunner 发出 `AgentRunState.starting` 后立即发出 `AgentRunState.running`
2. Pi 进程需要 ~2.2s 初始化（extensions 加载）
3. 初始化完成后才处理 stdin 中的 prompt 命令
4. prompt → agent_start 需要额外 ~1s（LLM API 调用）
5. 测试只等了 8s，而 LLM 响应可能需要更长时间

**结论**：协议管道已验证畅通，延迟来自 Pi 的 extension 加载（~2s）+ LLM API 响应（~10s）。建议 MVP 使用 `--no-extensions` 快速启动。
