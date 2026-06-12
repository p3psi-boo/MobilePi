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

**What**: Composer-only state such as selected model and short-lived sending
state should use `ValueNotifier`/`ValueListenableBuilder` or a small dedicated
widget state. Do not put these controls in the top-level screen `setState` when
the screen also owns long chat lists or Markdown output.

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

### Convention: Conversation Composer Routes Automatically

**What**: Task detail composer sends one plain message action. Do not expose a
manual steer/follow-up mode switch. `NodeProvider.sendComposerMessage()` decides
the protocol command: `running` and `waitingDecision` tasks use `sendSteer`,
while idle/history tasks use `sendFollowUp`.

**Why**: The user's high-frequency action is "send this message", not choosing a
transport command. Auto-routing keeps the conversation surface closer to mobile
chat ergonomics while preserving the protocol distinction behind the provider
boundary.

**Correct**:
```dart
provider.sendComposerMessage(taskId, text, model: selectedModel);
```

**Wrong**:
```dart
final isSteer = ValueNotifier(false);
isSteer.value ? provider.sendSteer(...) : provider.sendFollowUp(...);
```

**Tests Required**: Provider tests must assert that composer messages steer
`running` and `waitingDecision` tasks, follow up a non-running session, and add
optimistic user messages in all cases.

### Convention: Waiting Decisions Surface Inline Actions

**What**: Dashboard task rows with `status == 'waitingDecision'` should render
inline decision actions such as view, rethink, or stop. The rethink action
should call `NodeProvider.sendComposerMessage(taskId, ...)`, so it follows the
same auto-routing contract as the conversation composer.

**Why**: Waiting decisions are the commander workflow's most time-sensitive
state. Requiring users to open the detail screen before nudging the agent adds
an unnecessary navigation step and makes the Home surface less useful.

**Correct**:
```dart
if (task.status == 'waitingDecision') {
  WaitingActionRow(
    onRethink: () => provider.sendComposerMessage(task.id, prompt),
  );
}
```

**Wrong**:
```dart
Text('等待决策'); // no inline way to act
```

**Tests Required**: Dashboard widget tests must assert waiting task rows expose
inline actions, and tapping the rethink action sends a steer request through
`sendComposerMessage`.

### Convention: Task Cards Use Long-Press Action Sheets

**What**: Dashboard task rows should open a bottom sheet on long press for
secondary actions such as view conversation, view logs, stop, or remove local
history. Do not use swipe-to-delete for task cards.

**Why**: Task cards are dense and frequently scanned one-handed. Swipe
destructive actions are easy to trigger accidentally and conflict with native
back/scroll gestures; a long-press sheet is deliberate and leaves room for more
than one action.

**Correct**:
```dart
InkWell(
  onTap: openTask,
  onLongPress: showTaskActions,
  child: TaskCard(...),
)
```

**Wrong**:
```dart
Dismissible(
  direction: DismissDirection.endToStart,
  onDismissed: (_) => removeTask(task.id),
)
```

### Convention: Task Detail Logs Open In Context

**What**: Task detail should expose local logs through a small bottom handle near
the composer. Tapping the handle or swiping it upward opens a bottom sheet that
reuses the same log list component as the standalone logs screen.

**Why**: Logs are diagnostic context for the current conversation. Sending users
to a separate full-screen page interrupts the correction loop and makes the
mobile surface feel like an admin console.

**Correct**:
```dart
GestureDetector(
  onVerticalDragEnd: openLogsSheet,
  child: TaskLogDrawerHandle(),
);
```

**Wrong**:
```dart
Navigator.push(context, MaterialPageRoute(builder: (_) => LogsScreen()));
```

**Tests Required**: Task-detail widget tests must assert that the bottom log
handle opens an in-context sheet and renders records from `LogBuffer`.

### Convention: Task Detail Uses Edge-Swipe Back

**What**: Task detail should support a left-edge horizontal swipe to return to
Home. Only gestures that start near the screen edge should trigger navigation;
ordinary horizontal movement inside content must not pop the route.

**Why**: Conversation detail is the main drill-down surface. Edge-swipe back
matches mobile navigation muscle memory and keeps the top app bar from being
the only way out.

**Correct**:
```dart
onHorizontalDragStart: (details) {
  edgeSwipeActive = details.globalPosition.dx <= edgeSwipeWidth;
}
```

**Wrong**:
```dart
onHorizontalDragEnd: (_) => Navigator.maybePop(context); // any horizontal drag
```

**Tests Required**: Task-detail widget tests must push the detail route, perform
a rightward drag that starts at the left edge, and assert that the route pops
back to Home.

### Convention: Composer Keyboard Padding Is Compact

**What**: Bottom composers should add device safe-area padding only when the
keyboard is closed. When the keyboard is open, keep a compact fixed bottom
padding so the composer does not stack safe-area space on top of the resized
keyboard area.

**Why**: On small mobile screens, double-counting safe-area padding while the
keyboard is visible makes the composer unnecessarily tall and steals space from
the conversation.

**Correct**:
```dart
final keyboardOpen = MediaQuery.of(scaffoldParentContext).viewInsets.bottom > 0;
final bottomPadding = keyboardOpen ? 10.0 : safeAreaBottom + 10.0;
```

**Wrong**:
```dart
final keyboardOpen = MediaQuery.of(scaffoldBodyContext).viewInsets.bottom > 0;
```

`Scaffold` removes bottom `viewInsets` from its body subtree. Read keyboard
state above the `Scaffold` and pass it into composer widgets explicitly.

**Tests Required**: Task-detail widget tests must provide non-zero
`MediaQuery.viewInsets.bottom` and assert that composer bottom padding stays
compact instead of adding safe-area padding.

### Convention: Scroll Chrome State Stays Local

**What**: Scroll-driven affordances such as "jump to bottom" visibility should
use `ValueNotifier`/`ValueListenableBuilder` or an isolated widget state. Do not
call the owning screen's `setState` from high-frequency scroll listeners when
the screen contains chat lists or Markdown output.

**Why**: Conversation screens contain expensive children: sliver message lists,
streaming text, Markdown, and tool panels. A scroll direction change should
only rebuild the tiny floating control it affects, not the entire output view.

**Correct**:
```dart
_showJumpToBottom.value = !isNearBottom;

ValueListenableBuilder<bool>(
  valueListenable: _showJumpToBottom,
  builder: (_, show, __) => show ? JumpButton() : const SizedBox.shrink(),
);
```

**Wrong**:
```dart
void _onScroll() {
  setState(() => _showJumpToBottom = !isNearBottom);
}
```

**Boundary**: It is still fine to call top-level `setState` for structural
changes such as expanding/collapsing a turn or changing the history loading
sliver. The rule targets high-frequency scroll listeners and other tiny visual
affordances.

### Convention: Long Message Lists Do Not Keep Offscreen Children Alive

**What**: Chat/session `SliverList` delegates that render historical messages
should set `addAutomaticKeepAlives: false` and keep repaint boundaries enabled.

**Why**: Historical messages can contain Markdown, thinking blocks, and tool
panels. Keeping offscreen children alive preserves parsed/rendered trees for
content the user cannot see, increasing memory pressure during long sessions.

**Correct**:
```dart
SliverChildBuilderDelegate(
  buildMessage,
  childCount: messages.length,
  addAutomaticKeepAlives: false,
  addRepaintBoundaries: true,
);
```

**Wrong**:
```dart
SliverChildBuilderDelegate(buildMessage, childCount: messages.length);
```

**Boundary**: This rule applies to long, scrollable transcript/history lists.
Small fixed lists and controls may use framework defaults when retaining state
is intentional.

### Convention: Markdown Rendering Uses Bounded Memoization

**What**: Completed or historical Markdown should be rendered through
`PiMarkdown`, whose render cache is bounded and keyed by content plus resolved
theme/style inputs. Streaming live output should remain plain text until the
part is final.

**Why**: Long transcripts frequently destroy and recreate offscreen message
widgets. Without a cache, returning to a historical message reparses the same
Markdown and recreates code-block subtrees; without a bound, the cache itself
becomes a memory leak.

**Correct**:
```dart
isLive
    ? _LivePlainText(text: part.text!, style: style)
    : PiMarkdown(part.text!, style: style);
```

**Wrong**:
```dart
PiMarkdown(liveStreamingText);
```

**Tests Required**: Widget tests for `PiMarkdown` should cover cache reuse across
widget lifetimes and the configured cache size bound.

### Convention: Android Uses Explicit High Refresh Mode

**What**: Android builds should keep Impeller explicitly enabled in
`AndroidManifest.xml` and request the highest supported display mode for the
current resolution from `MainActivity`.

**Why**: Some Android devices and ROMs keep Flutter apps at 60 Hz unless the app
sets a preferred display mode. MobilePi's conversation screen depends on smooth
scrolling during streamed output, so platform refresh behavior should be an
explicit app contract rather than a device default.

**Correct**:
```kotlin
window.attributes = window.attributes.apply {
    preferredDisplayModeId = bestMode.modeId
}
```

**Wrong**:
```kotlin
// Rely on whatever refresh mode the OS chooses by default.
```

**Verification**: Run `flutter build apk --debug` after changing Android
activity or manifest code. On real high-refresh devices, confirm the selected
mode with platform diagnostics or a screen refresh-rate overlay.

---

## Props Conventions

<!-- How props should be defined and typed -->

(To be filled by the team)

---

## Styling Patterns

<!-- How styles are applied (CSS modules, styled-components, Tailwind, etc.) -->

### Convention: Semantic UI Colors Live in AppTokens

**What**: Brand colors, app surfaces, and status colors should come from the
`AppTokens` `ThemeExtension` (`Theme.of(context).appTokens`) or from
`ColorScheme`. Do not scatter raw `Color(0xFF...)` constants through screens.

**Why**: MobilePi needs one quiet visual language across dashboard,
conversation, logs, and sheets. Hardcoded green/yellow/red values drift quickly
and break dark-mode contrast.

**Correct**:
```dart
final tokens = Theme.of(context).appTokens;
final statusColor = tokens.statusForTask(task.status, cs);
```

**Wrong**:
```dart
final statusColor = const Color(0xFF4ADE80);
```

**Boundary**: Raw color constants are allowed inside the token definition file
itself, where they act as the single source of truth.

### Convention: Prefer Surface Steps Over Shadows

**What**: Use `surfaceContainer*` colors, borders, spacing, and typography for
visual hierarchy. Avoid `BoxShadow` in scrolling cards, composer surfaces, and
common panels.

**Why**: Soft shadows add visual noise and can create avoidable raster work on
mobile, especially while long transcript and dashboard lists scroll.

**Correct**:
```dart
decoration: BoxDecoration(
  color: cs.surfaceContainerLow,
  border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
)
```

**Wrong**:
```dart
boxShadow: [BoxShadow(blurRadius: 18)]
```

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

### Convention: Live Markdown Uses a Lightweight Fallback

**What**: While an assistant response is still streaming, render the currently
growing text/thinking parts as selectable plain text regardless of length.
Re-render the same content with `PiMarkdown` / `GptMarkdown` after the turn
becomes final.

**Why**: Large AI outputs often include tables, code spans, and incomplete
Markdown. Re-parsing the full growing string on every streaming delta can pin
the Flutter UI isolate and raster thread on mobile devices even before the text
becomes "long". A live plain-text fallback keeps typing responsive without
changing the final transcript.

**Correct**:
```dart
child: !isFinal
    ? _LivePlainText(text: text, style: style)
    : PiMarkdown(text, style: style),
```

**Wrong**:
```dart
child: PiMarkdown(streamingText);
```

**Boundary**: This applies only to live streaming content. Historical messages
and completed turns should keep full Markdown rendering so tables, code blocks,
links, and formatting remain available when the content is stable.

### Convention: Stable Markdown Is Memoized Per Widget Instance

**What**: Historical/completed Markdown renderers should reuse the rendered
`GptMarkdown` widget when the source text, style, and active theme have not
changed.

**Why**: `GptMarkdown` parses AI-generated Markdown during build. Historical
messages are stable, so rebuilding their parse tree when a parent scroll view
or provider selector updates wastes frame budget.

**Correct**:
```dart
if (_rendered != null && key == _renderKey) return _rendered!;
_rendered = buildMarkdown(context);
```

**Wrong**:
```dart
Widget build(BuildContext context) => GptMarkdown(message.text);
```

**Boundary**: Invalidate the cached render tree when text, dense/inverted mode,
explicit text style, or theme-derived colors/text styles change. Do not use a
global unbounded widget cache; keep memoization local to the renderer instance.

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
- Live `toolCall` / `toolResult` events must be appended to
  `TaskState.streamingParts` as `MessagePart.toolCall/toolResult` so streaming
  and historical rendering share the same structured source.
- Historical Pi session `parts` must preserve `toolCall` blocks with `name`,
  `id`, and `input` when present. Do not drop tool calls just because a later
  `toolResult` may exist; missing or out-of-order results would make the
  transcript incomplete.

**Tests Required**: Provider tests for streaming must assert that a
`thinking: "start"` event followed by deltas creates `MessagePart.thinking`,
that `thinking: "end"` switches subsequent deltas back to `MessagePart.text`,
and that render code does not use tag parsers or text stripping helpers.
Session-index tests must assert that toolCall blocks survive in historical
message `parts` with their id and input payload.

---

## Common Mistakes

<!-- Component-related mistakes your team has made -->

(To be filled by the team)
