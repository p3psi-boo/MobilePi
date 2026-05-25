# Top 3 Most Likely Injection Paths Where `usage` Is Lost

## Path 1: `PiSessionIndex.getSessionMessages()` — Probability 100%

**File:** `node/lib/agent/pi_session_index.dart` (lines 109–178)

**Mechanism:** This is the function called by `NodeDaemon._handleSessionMessagesRequest()` when the client requests chat history. It reads the session JSONL line-by-line and constructs `PiSessionMessageInfo` objects.

**Evidence:**
```dart
final contentBlocks = _extractContentBlocks(message);
final text = role == 'toolResult'
    ? _toolResultToMarkdown(message, contentBlocks)
    : _blocksToMarkdown(contentBlocks);

if (text.isNotEmpty) {
  final timestamp = _messageTimestampMs(message, entryMap);
  messages.add(
    PiSessionMessageInfo(
      role: role ?? '',
      text: text,
      timestamp: timestamp == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true),
      model: message['model']?.toString(),
    ),
  );
}
```

It extracts `role`, `text`, `timestamp`, and `model` only. `usage` is silently dropped.

**Why #1:** This is the **primary** code path for loading historical messages into the chat UI. Every time the user scrolls up or opens a task detail screen, this function runs. If the upstream JSONL contains `usage`, it is discarded here before it ever reaches the client.

---

## Path 2: `PiSessionIndex.buildSessionInfo()` — Probability 100%

**File:** `node/lib/agent/pi_session_index.dart` (lines 180–274)

**Mechanism:** Called when the daemon builds the session list for the node summary, and also when loading messages for the *active* session (`includeMessages: true`).

**Evidence:**
```dart
messages.add(
  PiSessionMessageInfo(
    role: role ?? '',
    text: text,
    timestamp: timestamp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true),
    model: message['model']?.toString(),
  ),
);
```

Same parser, same omission. Even the active session's messages in the node summary lose `usage`.

**Why #2:** This path feeds `piMessages` into the node summary, which the client receives on hello/resume. The client caches these in `NodeState.piMessages` and `TaskState.messages`.

---

## Path 3: `NodeDaemon._extractDeltaFromSessionLine()` — Probability 80%

**File:** `node/lib/daemon.dart` (lines 1424–1450)

**Mechanism:** During live session watching (`_pollSessionWatches`), the daemon tails the JSONL file and extracts text deltas to stream to the client in real time.

**Evidence:**
```dart
String? _extractDeltaFromSessionLine(String line) {
  // ...
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
}
```

This only extracts text content. No `usage` is extracted.

**Why #3 (lower probability):** This path is for **streaming display** only. The `_broadcastTaskUpdate` sends `streamingDelta` events, which the client renders as live text. The actual message with `usage` is not expected to arrive via streaming delta — it should be loaded later via `messages.list` (Path 1). However, if there is any logic that tries to reconstruct message metadata from the live tail, `usage` would be absent.

## Root Cause Summary

All three paths share a single root cause: **`PiSessionMessageInfo` has no `usage` field**, so every parser that builds this object necessarily drops `usage`. The fix must touch:
1. `PiSessionMessageInfo` — add `usage` field
2. `PiSessionIndex` — extract `usage` from JSONL
3. `NodeDaemon._extractDeltaFromSessionLine()` — optionally skip (streaming path)
4. `client` — decide whether/how to display usage
