# Tests/Scripts That Append Simplified Messages (role+content only, no usage)

## Production code: no writes

As confirmed in `02-jsonl-writers.md`, no production code in this repo writes to session JSONL.

## Test code: one location

### `node/test/daemon_sync_pi_only_test.dart` (lines 341–344)

```dart
await File(sessionPath).writeAsString(
  '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"external live delta"}]}}\n',
  mode: FileMode.append,
);
```

**What it does:** Simulates an external `pi` CLI appending a new assistant message to the session file while the daemon is watching it.

**Does it include `usage`?** No. The JSON line only contains:
- `role`: `"assistant"`
- `content`: `[{"type":"text","text":"external live delta"}]`

**Impact:** This is test-only code. It does not affect production sessions. However, it demonstrates that the test suite does not validate `usage` preservation because the fixture itself omits `usage`.

## Other tests

- `node/test/agent/pi_session_index_test.dart` — writes mock JSONL with `role` and `content` only (no `usage`). Lines 33–48.
- `client/test/providers/node_provider_sync_test.dart` — does not write files; sends protocol payloads with `sessionPath` but no on-disk I/O.

## Key insight

The test fixtures reflect the **current blind spot**: even if the upstream `pi` CLI writes `usage` into JSONL, MobilePi's tests never assert its presence because:
1. The fixtures don't include `usage`
2. The parser (`PiSessionIndex`) doesn't extract `usage`
3. The data model (`PiSessionMessageInfo`) has no `usage` field
