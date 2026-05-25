# Who Writes `~/.pi/agent/sessions/*.jsonl`

## Verdict: NO MobilePi layer writes session JSONL.

### Proof — Node layer

`node/lib/agent/pi_session_index.dart` is the **only** file in `node/lib/` that mentions `.jsonl`. It is read-only:
- `list()` → scans `~/.pi/agent/sessions/` for `.jsonl` files
- `getSessionMessages()` → reads lines, filters `"type":"message"`, extracts role/text/timestamp/model
- `buildSessionInfo()` → reads lines, extracts header, counts messages, extracts first user message text

No `FileMode.write`, `FileMode.append`, or `openWrite()` exists in `node/lib/` for `.jsonl`.

Command verification:
```bash
grep -rn "openWrite\|writeAsString\|writeAsBytes" node/lib/ --include="*.dart"
# → no output

grep -rn "jsonl" node/lib/ --include="*.dart"
# → only pi_session_index.dart (read-only operations)
```

### Proof — Hub layer

`hub/lib/server.dart` has zero file I/O beyond WebSocket routing. No jsonl references.

### Proof — Client layer

`client/lib/` has zero file I/O to `~/.pi/agent/sessions/`. Only `SharedPreferences` for settings/cursors.

### Writer is external: `pi` CLI

The session JSONL format is defined by the upstream `pi` coding agent (outside this repo). Example line structure observed in tests and referenced in `refs/pi-mono/`:

```json
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"hello"}],"usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150,"cost":{"input":0.001,"output":0.002,"cacheRead":0,"cacheWrite":0,"total":0.003}}}}
```

MobilePi is a **consumer** of this format, not a producer.
