# End-to-End Flow & Persistence Ownership

## Chain

```
Client (Flutter)  →  WebSocketService  →  HubServer  →  NodeDaemon  →  PiRunner  →  PiRpcClient  →  pi CLI (RPC mode)
      │                   │                  │              │              │             │                │
      │                   │                  │              │              │             │                │
   TaskState         MobilePiMessage    MobilePiMessage  MobilePiMessage AgentEvent   JSON-RPC lines   Session JSONL
   (in-memory)        (WS payload)       (WS payload)    (WS payload)  (Dart stream)  (stdin/stdout)  (~/.pi/agent/sessions/)
```

## Persistence Ownership Per Layer

| Layer | Persistence | Format | Notes |
|-------|-------------|--------|-------|
| **Client** | `SharedPreferences` (cursors, hubUrl, tenantKey) | Key-value | No message content persisted |
| **Hub** | None | — | Pure router; in-memory peer maps only |
| **NodeDaemon** | SQLite (`~/.mobilepi/node.db`) | `node_db.dart` | Tasks metadata + append-only event log for replay |
| **PiRunner / PiRpcClient** | None | — | Runtime-only wrapper around `pi` process |
| **pi CLI** | `~/.pi/agent/sessions/<encoded-cwd>/*.jsonl` | JSON Lines | **Transcript of truth**; writes session headers, `session_info`, and `message` lines |

## Key Observations

- **Only the external `pi` CLI writes session JSONL.** MobilePi never writes to it.
- MobilePi reads session JSONL in two places:
  1. `PiSessionIndex.getSessionMessages()` — paginated message fetch for chat history
  2. `PiSessionIndex.buildSessionInfo()` — session metadata for session list
  3. `NodeDaemon._pollSessionWatches()` — live tail for streaming deltas
- The `NodeDatabase` stores **task events** (streaming deltas, status changes) for replay, not the actual messages. The event log is a projection, not the source of truth.
- When the client requests chat history, the daemon calls `PiSessionIndex.getSessionMessages()` which reads the jsonl file directly.
