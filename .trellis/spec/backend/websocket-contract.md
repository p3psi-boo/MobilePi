# Single-User WebSocket Replay Contract

> **Scope**: Client ↔ Hub ↔ Node protocol, Node event-log persistence, and
> Client replay projection.
> **Status**: Active. The only wire protocol is `hello/resume/command/event/query/response/error`.

## 1. Scope / Trigger

- **Trigger**: Any change that touches `shared/lib/protocol`, `hub/lib/server.dart`,
  `node/lib/daemon.dart`, `node/lib/persistence/node_db.dart`,
  `client/lib/services/websocket_service.dart`, or `client/lib/providers/node_provider.dart`.
- **Reason**: Message shape, event ordering, SQLite persistence, Hub routing, and
  Flutter state projection are one cross-layer contract. Drift causes silent
  lost output after reconnect.

## 2. Signatures

### Shared envelope

```dart
MobilePiMessage(
  messageId: String,
  from: String,              // "client" | "hub" | "node:<nodeId>"
  to: String?,               // "hub" | "client" | "node:<nodeId>"
  type: MessageType,         // hello/resume/command/event/query/response/error
  kind: String?,             // mirrors the new protocol type for log readability
  protocolVersion: int = 1,
  payload: Map<String, dynamic>,
)
```

The JSON includes both `type` and `kind`; code branches on
`MessageType.hello/resume/command/event/query/response/error`.

### Tenant key

```dart
HubServer({required int port, required String tenantKey})
NodeDaemon({String? hubUrl, String? tenantKey})
WebSocketService({String? hubUrl, String? tenantKey})
```

Hub, Node, and Client share one user-defined tenant key. Hub requires a
non-empty key at startup, Node requires a non-empty key when `hubUrl` is used,
and Client must have a non-empty key before opening a Hub connection. The key is
carried only in `hello.payload.tenantKey`; Hub removes it before storing or
broadcasting Node summaries.

### Node database

```dart
NodeDatabase.appendEvent({
  required String streamId,
  required String type,
  required Map<String, dynamic> payload,
}) -> NodeEventRecord

NodeDatabase.eventsAfter(Map<String, int> cursors, {int limit = 500})
```

`appendEvent` assigns the next per-stream `seq` inside SQLite before any event
is sent over WebSocket.

## 3. Contracts

### Node hello

```json
{
  "type": "hello",
  "kind": "hello",
  "from": "node:<nodeId>",
  "to": "hub",
  "payload": {
    "tenantKey": "tenant-a",
    "nodeId": "node-1",
    "hostname": "macbook",
    "platform": "macos",
    "agents": ["pi"],
    "online": true,
    "piModels": [],
    "piSlashCommands": [],
    "piInstances": [],
    "piState": {},
    "piMessages": [],
    "piSessions": []
  }
}
```

Hub validates `tenantKey`, removes it from the stored in-memory Node summary,
and does not persist business data.

### Client hello

```json
{
  "type": "hello",
  "kind": "hello",
  "from": "client",
  "to": "hub",
  "payload": {
    "tenantKey": "tenant-a",
    "clientId": "client-uuid",
    "deviceName": "MobilePi Client",
    "lastCursors": {
      "node-1": {"task:abc": 42}
    }
  }
}
```

Hub allows one active Client. A new Client registration closes the old active
Client connection and returns:

```json
{
  "type": "response",
  "kind": "response",
  "from": "hub",
  "to": "client",
  "payload": {
    "responseTo": "client-hello-message-id",
    "nodeSummaries": []
  }
}
```

### Environment wiring

- `MOBILE_PI_TENANT_KEY` configures Hub, Node, and Flutter builds.
- `MOBILE_PI_HUB_WS_URL` still configures Hub URL for Node and Client.
- Local `just hub` / `just daemon` pass `MOBILE_PI_TENANT_KEY`; an empty key is a
  startup/configuration error for Hub-connected mode.

### Resume

Client sends one resume per online Node:

```json
{
  "type": "resume",
  "kind": "resume",
  "from": "client",
  "to": "node:<nodeId>",
  "payload": {
    "cursors": {"task:abc": 42},
    "includeNodeSummary": true
  }
}
```

Node returns:

```json
{
  "type": "response",
  "kind": "response",
  "from": "node:<nodeId>",
  "to": "client",
  "payload": {
    "responseTo": "resume-message-id",
    "nodeSummary": {},
    "events": [],
    "hasMore": false,
    "truncatedStreams": [
      {
        "streamId": "task:abc",
        "requestedSeq": 10,
        "fromSeq": 14,
        "latestSeq": 20,
        "snapshot": {
          "streamId": "task:abc",
          "seq": 20,
          "type": "task.snapshot",
          "taskId": "abc",
          "payload": {
            "taskId": "abc",
            "agentType": "pi",
            "title": "Fix login bug",
            "status": "running",
            "projectPath": "/repo",
            "model": "provider/model",
            "sessionPath": "/home/me/.pi/sessions/abc.jsonl"
          },
          "createdAt": "2026-05-20T12:00:00.000Z"
        }
      }
    ]
  }
}
```

Replay ordering is global insertion order, not `streamId` lexical order:
`NodeDatabase.eventsAfter(cursors)` scans the event log by global `events.id`
and filters each row with `seq > cursor[streamId]` (unknown streams use cursor
`0`). When a requested cursor is older than the retained event window for a
known stream, Node must include a `truncatedStreams` entry. If the task row still
exists, the entry must include a `task.snapshot` event whose `seq` is the latest
known stream seq. Node caps each response to the replay page size and sets
`hasMore: true` when another page remains. Client must apply truncated snapshots
before replay `events`, then advance the local `(nodeId, streamId)` cursor to
the snapshot/event seq. If `hasMore` is true, Client immediately sends another
resume for that Node using the advanced cursor map until a response returns
`hasMore: false`.

### Historical Session Pagination

Historical Pi session message responses must attach a stable `sourceIndex` to
each message. `sourceIndex` is the zero-based index of that message in the
underlying session message stream / JSONL message list; it is not the index in
the current page. When a response includes `nextBeforeIndex`, that value is the
start index of the returned page and can be used as the cursor for loading older
messages.

Clients must dedupe paginated historical messages by `sourceIndex` within the
owning task/session. Content signatures such as role + text + parts are allowed
only as a compatibility fallback for old cached/session-preview records that do
not yet carry `sourceIndex`.

Historical `parts` are the lossless transcript source for tool rendering. A
`toolCall` part must preserve the tool `name`, stable call `id`, and structured
`input` payload when Pi provides them. The matching `toolResult` part must carry
the same stable `id` (from `id`, `toolCallId`, or equivalent Pi fields), plus
`name`, `status`, and result `text`, so clients can pair calls/results without
guessing from display text.

### Event

```json
{
  "type": "event",
  "kind": "event",
  "from": "node:<nodeId>",
  "to": "client",
  "payload": {
    "streamId": "task:<taskId>",
    "seq": 43,
    "type": "task.output.delta",
    "taskId": "<taskId>",
    "payload": {
      "taskId": "<taskId>",
      "status": "running",
      "streamingDelta": "running tests\n"
    },
    "createdAt": "2026-05-20T12:00:00.000Z"
  }
}
```

`streamingText` and `streamingDelta` are lossless protocol fields. Node must not
truncate or replace them before appending the event or sending it to clients.
Clients may limit the visible render window for performance, but the event
payload and projected task state must retain the complete received text.

Client must apply an event only when `seq > localCursor[nodeId][streamId]`, then
advance the cursor to `seq` and persist cursors with low-frequency batching.

### Command

Task commands use the protocol envelope:

```json
{
  "type": "command",
  "kind": "command",
  "from": "client",
  "to": "node:<nodeId>",
  "payload": {
    "type": "task.create",
    "requestId": "uuid",
    "taskId": "uuid",
    "agentType": "pi",
    "prompt": "run tests",
    "projectPath": "/Users/bubu/remote-agent",
    "model": "provider/model"
  }
}
```

Supported command payload `type` values:

- `task.create`
- `task.follow_up`
- `task.steer`
- `task.panic`
- `cursor.ack`

`requestId` is the idempotency key. Node records it in `command_requests`.

### Heartbeat / Half-Open Detection

Client-to-Hub and Node-to-Hub sockets both use protocol `ping` / `pong` to
detect half-open mobile or Wi-Fi transitions. The interval is 15 seconds and the
maximum missed pong count is 2, so a silent connection should be detected in
about 30 seconds. Reconnect backoff remains exponential from 1 second to 30
seconds, with jitter.

Flutter app foreground resume should force a reconnect/resume even when the
socket object still claims to be connected, because mobile backgrounding can
leave a stale TCP connection that will not fail until heartbeat timeout.

## 4. Validation & Error Matrix

| Condition | Behavior |
| --- | --- |
| Unknown JSON or enum type | Log warning, keep socket open when possible |
| Hub starts with empty tenant key | Throw/exit before accepting sockets |
| Node starts in Hub mode with empty tenant key | Throw before connecting to Hub |
| Client has empty tenant key | Do not connect; user must fill the key in settings |
| Hello missing or mismatching `tenantKey` | Hub sends protocol `error` with `code: invalid_tenant_key` and closes the socket |
| Non-hello message arrives before successful hello | Hub returns protocol `error` with `code: unauthenticated_peer` and does not route |
| Client sends `to: node:<id>` and Node is offline | Hub logs route miss; future work may return route error |
| Node sends `to: client` | Hub forwards to the one active Client |
| New Client connects while another is active | Hub closes old Client and promotes the new one |
| Command missing payload `type` | Node returns protocol `error` with `code: missing_command_type` |
| Duplicate command `requestId` | Node returns stored result and does not repeat the command |
| `seq <= cursor` on Client | Client ignores event as duplicate/replay |
| Resume cursor predates retained event window | Node returns `truncatedStreams[]` with latest task snapshot when available |
| 2 consecutive heartbeat pongs are missed | Peer closes the socket and schedules reconnect/resume |
| Direct-mode Node tests | Node must not block socket bind on real Pi capability loading |
| Old incompatible `tasks` table exists | Node drops only the incompatible legacy table, then creates the new schema |

## 5. Good / Base / Bad Cases

**Good**: Hub starts with tenant key → Node connects to Hub with matching
`hello.payload.tenantKey` → Client connects with the same key → Hub returns node
summaries → Client sends `resume` → Node returns replay events where
`seq > cursor` → Client applies them and advances cursors.

**Base**: Client resumes with a cursor older than Node's retained events. Node
returns a `truncatedStreams` snapshot for that stream, Client applies the
snapshot first, advances the cursor to `latestSeq`, and ignores older replay
events from the same response.

**Base**: Pi RPC capability loading fails. Node still registers with `agents:
["pi"]` and empty capability arrays. Task commands can still run with Pi defaults.

**Bad**: An unauthenticated socket sends `event` to `client` before hello. Hub
must reject it as `unauthenticated_peer`; otherwise a rejected peer could bypass
registration and inject client-visible messages.

## 6. Tests Required

- **Shared**: generated `messages.g.dart` includes the protocol message types,
  `kind`, and default `protocolVersion`.
- **Node DB**: `test/persistence/node_db_test.dart` must assert new tables exist,
  incompatible legacy tables are migrated, `appendEvent/eventsAfter` preserve
  per-stream seq and global insertion order, and purged streams produce
  `truncatedStreams` snapshots.
- **Node daemon**: `test/daemon_sync_pi_only_test.dart` must assert protocol
  `task.create` emits `event` envelopes, `resume` replays persisted events, and
  resume pagination sets `hasMore` with exactly one page of events.
- **Hub**: `test/server_test.dart` must assert protocol `hello` registration,
  tenant-key rejection, unauthenticated route rejection, `node:<id>` routing,
  and `to: client` routing.
- **Client**: `test/providers/node_provider_sync_test.dart` must assert protocol
  events append output, advance cursor, ignore duplicate seq, apply truncated
  stream snapshots before replay events, re-resume with advanced cursors when
  `hasMore` is true, and block connect until a tenant key is configured.
- **Manual e2e**: `node/test/e2e/e2e_test.dart` requires a live daemon at
  `ws://localhost:9000/ws`; do not treat plain `dart test` failure for that file
  as a unit-test regression without starting the daemon first.

## 7. Wrong vs Correct

### Wrong — live event without persistence

```dart
channel.sink.add(jsonEncode(protocolEvent(payload).toJson()));
db.appendEvent(...); // too late
```

### Correct — persist first, then send

```dart
final event = db.appendEvent(
  streamId: 'task:$taskId',
  type: 'task.output.delta',
  payload: payload,
);
channel.sink.add(jsonEncode(protocolEvent(event).toJson()));
```

### Wrong — route new protocol to a raw node id only

```dart
message.to = nodeId;
```

### Correct — address new protocol targets explicitly

```dart
message.to = 'node:$nodeId';
```

Hub only routes canonical protocol targets.

### Wrong — route before hello authentication

```dart
case MessageType.event:
  _routeMessage(message);
```

### Correct — route only registered channels

```dart
if (!_isRegisteredChannel(channel)) {
  _sendProtocolError(channel, message, 'unauthenticated_peer');
  return;
}
_routeMessage(channel, message);
```

## Design Decision: Node-Local Event Log

**Context**: Single-user MobilePi needs reliable reconnect without a central
business database.

**Decision**: Node is the source of truth for task event replay. Hub remains an
in-memory relay with one active Client. Client is a disposable projection that
uses per-stream cursors to recover.

**Consequence**: The durable contract is `(nodeId, streamId, seq)`, not transport
`messageId` and not Hub-local client ids.
