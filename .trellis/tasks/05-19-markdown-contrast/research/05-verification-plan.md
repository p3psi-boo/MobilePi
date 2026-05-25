# Verification Plan — Distinguish the 3 Injection Paths

## Pre-req: Create a session JSONL with `usage`

```bash
mkdir -p /tmp/mobilepi-verify/sessions
cat > /tmp/mobilepi-verify/sessions/test.jsonl <<'EOF'
{"type":"session","id":"verify-session","cwd":"/tmp","timestamp":"2026-05-25T00:00:00.000Z"}
{"type":"message","timestamp":"2026-05-25T00:00:01.000Z","message":{"role":"user","content":"hello","timestamp":1716200000000}}
{"type":"message","timestamp":"2026-05-25T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"world"}],"timestamp":1716200001000,"model":"claude-sonnet-4","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15,"cost":{"input":0.0001,"output":0.0002,"cacheRead":0,"cacheWrite":0,"total":0.0003}}}}
EOF
```

---

## Verify Path 1: `PiSessionIndex.getSessionMessages()`

```bash
cd /Users/bubu/remote-agent/node
dart run -c <<'EOF'
import 'package:mobilepi_node/agent/pi_session_index.dart';

void main() async {
  final res = await PiSessionIndex.getSessionMessages(
    sessionPath: '/tmp/mobilepi-verify/sessions/test.jsonl',
    limit: 10,
  );
  final messages = res?['messages'] as List? ?? [];
  for (final m in messages) {
    print('role=${m['role']} model=${m['model']} usage=${m['usage']}');
  }
}
EOF
```

**Expected:** `usage=null` for the assistant message. This confirms Path 1 drops `usage`.

---

## Verify Path 2: `PiSessionIndex.buildSessionInfo()`

```bash
cd /Users/bubu/remote-agent/node
dart run -c <<'EOF'
import 'dart:io';
import 'package:mobilepi_node/agent/pi_session_index.dart';

void main() async {
  final info = await PiSessionIndex.buildSessionInfo(
    File('/tmp/mobilepi-verify/sessions/test.jsonl'),
    includeMessages: true,
  );
  for (final m in info?.messages ?? []) {
    print('role=${m.role} model=${m.model} usage=${(m as dynamic).usage}');
  }
}
EOF
```

**Expected:** `usage=null` (or compile error if casting). Confirms Path 2 drops `usage`.

---

## Verify Path 3: `NodeDaemon._extractDeltaFromSessionLine()`

```bash
cd /Users/bubu/remote-agent/node
dart run -c <<'EOF'
import 'dart:convert';

String? extractDelta(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  try {
    final obj = jsonDecode(trimmed);
    if (obj is! Map) return null;
    if (obj['type']?.toString() != 'message') return null;
    final msg = obj['message'];
    if (msg is! Map) return null;
    if (msg['role']?.toString() != 'assistant') return null;
    final content = msg['content'];
    if (content is! List) return null;
    final parts = <String>[];
    for (final item in content) {
      if (item is Map && item['type']?.toString() == 'text') {
        final text = item['text']?.toString();
        if (text != null && text.isNotEmpty) parts.add(text);
      }
    }
    if (parts.isEmpty) return null;
    return parts.join('\n');
  } catch (_) {
    return null;
  }
}

void main() {
  final line = '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"external live delta"}],"usage":{"input":10,"output":5}}}\n';
  final delta = extractDelta(line);
  print('delta=$delta');
  print('usage preserved? ${delta == null || !delta.contains("usage")}');
}
EOF
```

**Expected:** `delta=external live delta`, usage not present. Confirms Path 3 is text-only.

---

## Verify Data Model: `PiSessionMessageInfo`

```bash
cd /Users/bubu/remote-agent/node
grep -A10 "class PiSessionMessageInfo" lib/agent/pi_capabilities.dart
```

**Expected:** Fields are `role`, `text`, `timestamp`, `model`. No `usage`.

---

## Verify No Production Writes to JSONL

```bash
cd /Users/bubu/remote-agent
grep -rn "FileMode.append\|openWrite" node/lib/ hub/lib/ client/lib/ --include="*.dart"
```

**Expected:** No output. Confirms MobilePi is read-only for session JSONL.
