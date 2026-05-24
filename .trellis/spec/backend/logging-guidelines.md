# Logging Guidelines

> How logging is done in this project.

---

## Overview

Use the Dart `logging` package in Hub, Node, and Client. Shared formatting and
message-summary helpers live in `mobilepi_shared`:

```dart
formatLogRecord(record)
logField('taskId', shortId(taskId))
logFields({'event': 'task.started'})
summarizeMessage(message)
summarizeJsonMessage(messageJson)
```

Operational log messages should start with an explicit `event=<name>` token and
then use `key=value` fields. Prefer stable identifiers and counts over prose.

---

## Log Levels

<!-- When to use each level: debug, info, warn, error -->

- Use `fine` for low-level child process stream chunks and protocol diagnostics.
- Use `info` for successful lifecycle transitions that operators need to
  distinguish from silent success, such as a restored session receiving a prompt.
- Use `warning` when a command cannot be fulfilled or recovery is needed.
- Use `severe` when an agent runner cannot start or resume and the task enters
  an error state.

---

## Structured Logging

Console logs should be written through `formatLogRecord(record)` so Hub and Node
use the same timestamp/level/logger/error/stack format.

Protocol boundary logs must use message summaries:

```dart
_logger.fine('event=ws.receive ${summarizeMessage(message)}');
_logger.fine('event=ws.send ${summarizeJsonMessage(messageJson)}');
```

Do not hand-format raw JSON envelopes in logs. `summarizeMessage` keeps
`messageId`, `type`, `from`, `to`, `command`, `requestId`, `taskId`,
`streamId`, and `payloadKeys` while omitting raw payload values such as prompts.

IDs that are only needed for correlation should be shortened with `shortId`.
Long text inputs should be logged as `promptLength` or `messageLength`.

---

## What to Log

<!-- Important events to log -->

- Log successful asynchronous boundaries when the absence of a line would make a
  stalled workflow indistinguishable from a successful one.
- Log connect/disconnect/reconnect, command accept/reject/duplicate, task
  start/resume/panic, runner completion/error, directory browse/create results,
  Pi capability load success/failure, and WebSocket route misses.
- When logging raw child process chunks, make whitespace visible with
  `jsonEncode(chunk)` or an equivalent escaped representation.
- Filter known terminal notification control sequences, such as OSC 777 and
  Kitty OSC 99, before logging child-process stderr chunks. Keep any surrounding
  non-notification stderr text.

---

## What NOT to Log

<!-- Sensitive data, PII, secrets -->

- Do not add new logs for secrets, tokens, or raw environment values.
- Do not log raw `prompt`, `message`, tool output, full protocol payloads, raw
  Pi RPC lines, cookies, authorization headers, or API keys.
- Do not concatenate `$e\n$st` into the message. Pass `error` and `stackTrace`
  as logger arguments so `formatLogRecord` can render them consistently.

## Correct / Wrong

Correct:

```dart
_logger.info(
  'event=task.started ${logFields({
    'taskId': shortId(taskId),
    'instanceId': instanceId,
    'promptLength': prompt.length,
  })}',
);
```

Wrong:

```dart
_logger.info('Task $taskId started with prompt: $prompt');
```

The wrong form leaks user input and is harder to search reliably across Hub,
Node, and Client logs.

## Tests Required

- Shared logging helpers must have unit tests for sensitive field redaction.
- Protocol message summaries must have tests proving raw prompt text is not
  emitted.
- Changes to WebSocket or command routing should keep Hub, Node, and Client
  tests passing because logs now rely on the same protocol summaries.
