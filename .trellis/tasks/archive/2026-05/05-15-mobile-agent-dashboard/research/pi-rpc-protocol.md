# Pi RPC Protocol Research

> Source: `refs/pi-mono/packages/coding-agent/docs/rpc.md`

## Pi Agent 启动方式

```bash
pi --mode rpc [options]
```

常用选项：
- `--provider <name>`: anthropic, openai, google, etc.
- `--model <pattern>`: 模型 ID
- `--no-session`: 禁用会话持久化
- `--session-dir <path>`: 自定义会话存储目录

## 协议格式

**输入**（stdin，JSONL，每行一条命令）：
```json
{"type": "prompt", "message": "实现一个 REST API"}
{"type": "steer", "message": "停止，换个思路"}
{"type": "abort"}
```

**输出**（stdout，JSONL，流式事件）：
```json
{"type": "agent_start"}
{"type": "turn_start"}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "delta": "Hello..."}}
{"type": "tool_execution_start", "toolCallId": "call_123", "toolName": "bash"}
{"type": "tool_execution_end", "toolCallId": "call_123", "result": {...}}
{"type": "turn_end"}
{"type": "agent_end"}
```

## 关键事件类型

| 事件 | 用途 |
|---|---|
| `agent_start` | Agent 开始处理 |
| `agent_end` | Agent 完成 |
| `turn_start` | 新 turn 开始 |
| `turn_end` | Turn 完成 |
| `message_start/end` | 消息开始/结束 |
| `message_update` | 流式更新（text_delta/thinking_delta/toolcall_delta） |
| `tool_execution_start/end` | 工具执行开始/结束 |
| `tool_execution_update` | 工具执行进度 |
| `queue_update` | steering/follow-up 队列变化 |

## 对 MobilePi 的映射

- Pi 的 `agent_start` → MobilePi `taskUpdate(status: running)`
- Pi 的 `message_update` → MobilePi `taskUpdate(progress: text/streaming)`
- Pi 的 `tool_execution_start` → MobilePi `taskUpdate(status: running, tool: bash/edit/etc)`
- Pi 的 `agent_end` → MobilePi `taskUpdate(status: completed)`
- Pi 的 `abort` 命令 → MobilePi `panic` 消息的响应

## Node 端实现要点

1. 用 `Process.start('pi', ['--mode', 'rpc'])` 启动子进程
2. stdin 写 JSONL 命令
3. stdout 读 JSONL 事件，解析后翻译为 MobilePiMessage(taskUpdate)
4. 进程退出或 `abort` 命令终止
