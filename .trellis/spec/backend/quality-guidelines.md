# Quality Guidelines

> Code quality standards for backend development.

---

## Overview

<!--
Document your project's quality standards here.

Questions to answer:
- What patterns are forbidden?
- What linting rules do you enforce?
- What are your testing requirements?
- What code review standards apply?
-->

(To be filled by the team)

---

## Forbidden Patterns

<!-- Patterns that should never be used and why -->

(To be filled by the team)

---

## Required Patterns

<!-- Patterns that must always be used -->

### Convention: Preserve UTF-8 Boundaries in Tail Followers

**What**: Any daemon code that tails Pi JSONL/session files must keep partial
lines as bytes, split on LF bytes, and decode only complete lines with strict
UTF-8.

**Why**: File watchers can observe writes in the middle of a multi-byte
character. Decoding each chunk with `allowMalformed: true` permanently replaces
split Chinese/Japanese/etc. characters with U+FFFD before the remaining bytes
arrive.

**Correct**:
```dart
final chunk = [...partialBytes, ...bytes];
// split complete lines on 0x0a, store trailing bytes as partialBytes
final line = utf8.decode(lineBytes);
```

**Wrong**:
```dart
final chunk = partialText + utf8.decode(bytes, allowMalformed: true);
partialText = chunk.split('\n').removeLast();
```

### Convention: Tail Deduplication Uses File Offsets

**What**: Session tail followers must identify emitted lines by their starting
byte offset in the tailed file, not by hashing the decoded content.

**Why**: Pi can legitimately emit identical assistant text on separate JSONL
lines. Content hashes collapse distinct events, while a line byte offset is
monotonic for append-only tailing and naturally survives repeated content.

**Correct**:
```dart
final lineId = lineStartByteOffset;
if (!seenLineOffsets.add(lineId)) return;
```

**Wrong**:
```dart
final sig = '${taskId}:${delta.hashCode}';
if (!recentFingerprints.add(sig)) return;
```

---

## Testing Requirements

<!-- What level of testing is expected -->

- Session tail-follow tests must include a JSONL line split in the middle of a
  multi-byte UTF-8 character and assert the emitted delta preserves the original
  text.
- Session tail-follow tests must include two distinct appended JSONL lines with
  identical assistant text and assert both deltas are emitted.

---

## Code Review Checklist

<!-- What reviewers should check -->

(To be filled by the team)
