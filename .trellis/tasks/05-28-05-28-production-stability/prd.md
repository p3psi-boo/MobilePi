# Production Stability Fixes

## Scope
Fix 7 production-readiness issues identified during codebase audit.

## Items

| # | Item | Packages | Agent |
|---|------|----------|-------|
| 2 | Eliminate silent `catch(_) {}` blocks — add logging | node | A |
| 3 | Add jitter to reconnection timers | node, client | A, C |
| 4 | SQLite WAL mode + busy_timeout | node | A |
| 5 | Memory growth limits (events TTL, task map cleanup, streamingText cap) | node, hub, client | A, B, C |
| 6 | Graceful shutdown with timeouts | node, hub | A, B |
| 7 | systemd/launchd service files + SIGTERM handlers | deploy, bin | C |
| 8 | Hub /health endpoint | hub | B |

## Agent split (no file conflicts)

- **Agent A (Node)**: `node/lib/daemon.dart`, `node/lib/agent/pi_session_index.dart`, `node/lib/persistence/node_db.dart`
- **Agent B (Hub)**: `hub/lib/server.dart`
- **Agent C (Client + Deploy)**: `client/lib/services/websocket_service.dart`, `client/lib/providers/node_provider.dart`, `node/bin/node.dart`, `hub/bin/hub.dart`, new `deploy/`
