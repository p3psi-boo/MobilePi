# Component Guidelines

> How components are built in this project.

---

## Overview

MobilePi client components expose a commander-style conversation surface. The
wire protocol uses `command` envelopes and `TaskState`, but user-facing screens
should describe the primary interaction as a conversation/session unless the UI
is explicitly explaining runtime internals.

---

## Component Structure

<!-- Standard structure of a component file -->

(To be filled by the team)

### Convention: New Work Starts as a Blank Conversation

**What**: The primary create action opens a blank conversation/session screen
with a single prompt input. Do not require users to pick Node, Pi instance,
model, slash command, or agent routing before they can type.

**Why**: Node selection, Pi instance choice, and model selection are routing
details. Exposing them as required setup turns a ChatGPT-style mobile flow into
an admin form and makes "new task" look like a separate product concept.

**Correct**:
```dart
FloatingActionButton.extended(
  onPressed: _openCreateTask,
  icon: const Icon(Icons.add),
  label: const Text('新对话'),
);
```

**Wrong**:
```dart
DropdownButtonFormField<String>(
  decoration: const InputDecoration(labelText: 'Pi 模型'),
);
```

**Boundary**: It is still fine for `NodeProvider` and `WebSocketService` to
send `command` payloads with `type: task.create`, `piInstanceId`, and `model`; the UI should fill
those from defaults unless an explicit advanced-settings surface exists.

### Convention: Slash Commands Use a Composer Entry Button

**What**: In the chat/session composer, available Pi slash commands should be
collapsed behind one command button. Tapping it opens a bottom sheet with a
scrollable list of commands.

**Why**: Slash commands are optional accelerators, not primary composer modes.
Flattening every command into the composer strip creates horizontal clutter and
makes the chat surface feel like an admin toolbar.

**Correct**:
```dart
_ComposerAction(
  label: '命令',
  icon: Icons.terminal,
  onTap: () => _showCommandSheet(context, node.piSlashCommands),
);
```

**Wrong**:
```dart
for (final command in node.piSlashCommands.take(10)) {
  actions.add(_ComposerAction(label: '/${command.name}', onTap: ...));
}
```

**Boundary**: The bottom sheet should show both the command label and its
description, and selection should insert the same prompt text the old shortcut
would have inserted. Do not change `NodeProvider` or WebSocket payloads for a
pure composer presentation change.

### Convention: Composer State Stays Local

**What**: Composer-only toggles such as selected model, steer/follow-up mode, and
short-lived sending state should use `ValueNotifier`/`ValueListenableBuilder` or
a small dedicated widget state. Do not put these controls in the top-level
screen `setState` when the screen also owns long chat lists or Markdown output.

**Why**: Task detail and task creation screens contain expensive children:
streamed Markdown, message lists, command sheets, and project/session context.
Changing a chip selection should rebuild the composer controls only, not the
entire conversation surface.

**Correct**:
```dart
final _selectedModel = ValueNotifier<String?>(null);

ValueListenableBuilder<String?>(
  valueListenable: _selectedModel,
  builder: (context, selectedModel, _) => _Composer(
    selectedModel: selectedModel,
  ),
);
```

**Wrong**:
```dart
onModelChanged: (model) => setState(() => _selectedModel = model);
```

**Boundary**: Provider-backed task state still belongs in `NodeProvider` and
should be consumed with `Selector`/`Consumer`. This convention is only for
ephemeral UI control state that has no protocol or persistence meaning.

---

## Props Conventions

<!-- How props should be defined and typed -->

(To be filled by the team)

---

## Styling Patterns

<!-- How styles are applied (CSS modules, styled-components, Tailwind, etc.) -->

(To be filled by the team)

---

## Accessibility

<!-- A11y requirements and patterns -->

(To be filled by the team)

---

## Markdown Rendering

**What**: When rendering Markdown in Flutter, prefer using the `GptMarkdown` widget.

**Why**: `gpt_markdown` is specifically optimized for AI-generated content. It handles common issues like missing blank lines before tables, LaTeX math formulas, and "streaming" text flickers much better than standard packages.

**Pattern**:
```dart
GptMarkdown(
  message.text,
  style: theme.textTheme.bodyMedium,
  // Add other properties as needed
)
```

### Convention: Streaming Rendering Uses Structured Protocol Fields Only

**What**: Client chat renderers must render thinking blocks, tool calls, and
tool results from structured protocol fields, not by parsing tags in text.

**Why**: Pi emits `thinking: "start"`, plain `streamingDelta` chunks, then
`thinking: "end"`. Tool activity arrives via `toolCall` / `toolResult` payload
objects. The client can preserve these boundaries as typed state, so regex or
string matching against `<thinking>`, `<tool_result>`, `[工具: ...]`, or
`<skill>` is unnecessary and can leak reasoning when a stream is rebuilt
mid-turn.

**Correct**:
```dart
final nextParts = appendStreamingDelta(
  existingParts,
  delta,
  isThinking: task.isThinking,
);
return _buildHistoryPartWidgets(context, task.streamingParts);
```

**Wrong**:
```dart
final parts = tagRegex.allMatches(streamingText);
final preview = stripTags(message.text);
```

**Payload Contract**:
- `streamingDelta`: plain text only; no structural marker injection.
- `thinking`: `"start"` / `"end"` boundary that controls whether subsequent
  deltas append to a `MessagePart.thinking` or `MessagePart.text`.
- `toolCall` / `toolResult`: structured tool event objects rendered as tool UI,
  never inferred from text.

**Tests Required**: Provider tests for streaming must assert that a
`thinking: "start"` event followed by deltas creates `MessagePart.thinking`,
that `thinking: "end"` switches subsequent deltas back to `MessagePart.text`,
and that render code does not use tag parsers or text stripping helpers.

---

## Common Mistakes

<!-- Component-related mistakes your team has made -->

(To be filled by the team)
