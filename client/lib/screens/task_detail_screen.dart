import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/node_state.dart';
import '../providers/node_provider.dart';
import '../theme/app_tokens.dart';
import '../widgets/pi_markdown.dart';
import '../widgets/task_status_bar.dart';
import 'logs_screen.dart';

/// 任务详情页 — 展示完整输出流 + Steering/Follow-up 输入
const int _maxRenderedStreamingChars = 24000;

class TaskDetailScreen extends StatefulWidget {
  final String taskId;

  const TaskDetailScreen({super.key, required this.taskId});

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  static const double _edgeSwipeWidth = 24;
  static const double _edgeSwipePopDistance = 72;

  final _inputController = TextEditingController();
  final _inputFocusNode = FocusNode();
  // Keep composer-only state out of the page rebuild path.
  final _selectedModel = ValueNotifier<String?>(null); // null = node default
  bool _edgeSwipeActive = false;
  double _edgeSwipeDistance = 0;
  bool _errorCardDismissed = false;
  bool _retryMode = false;
  final _outputViewKey = GlobalKey<_OutputViewState>();

  @override
  void dispose() {
    _selectedModel.dispose();
    _inputController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    HapticFeedback.lightImpact();
    final provider = context.read<NodeProvider>();
    provider.sendComposerMessage(
      widget.taskId,
      text,
      model: _selectedModel.value,
    );
    _inputController.clear();
    setState(() => _retryMode = false);
  }

  void _activateRetry(TaskState task) {
    final lastUserMsg = task.messages
        .lastWhere((m) => m.role == 'user', orElse: () => task.messages.last);
    _inputController.text = lastUserMsg.text;
    _inputController.selection = TextSelection.collapsed(
      offset: _inputController.text.length,
    );
    _inputFocusNode.requestFocus();
    setState(() => _retryMode = true);
  }

  @override
  Widget build(BuildContext context) {
    final taskListenable = context.read<NodeProvider>().taskListenable(
      widget.taskId,
    );

    return ValueListenableBuilder<TaskState?>(
      valueListenable: taskListenable,
      builder: (context, task, _) {
        final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
        if (task == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('任务不存在')),
            body: const Center(child: Text('任务未找到')),
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: _onHorizontalDragStart,
          onHorizontalDragUpdate: _onHorizontalDragUpdate,
          onHorizontalDragEnd: _onHorizontalDragEnd,
          child: Scaffold(
            appBar: PreferredSize(
              preferredSize: const Size.fromHeight(kToolbarHeight),
              child: _TaskAppBar(
                taskId: widget.taskId,
                outputViewKey: _outputViewKey,
              ),
            ),
            body: Column(
              children: [
                TaskStatusBar(taskId: widget.taskId),
                Expanded(child: _OutputView(key: _outputViewKey, taskId: widget.taskId)),
                if (task.status == 'error' && !_errorCardDismissed)
                  _TaskErrorCard(
                    task: task,
                    onRetry: () => _activateRetry(task),
                    onDismiss: () => setState(() => _errorCardDismissed = true),
                  ),
                const _TaskLogDrawerHandle(),
                _TaskInputBarWrapper(
                  taskId: widget.taskId,
                  controller: _inputController,
                  focusNode: _inputFocusNode,
                  selectedModelListenable: _selectedModel,
                  onModelChanged: (m) => _selectedModel.value = m,
                  keyboardOpen: keyboardOpen,
                  onSend: _send,
                  retryMode: _retryMode,
                  onCancelRetry: () {
                    _inputController.clear();
                    setState(() => _retryMode = false);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _edgeSwipeActive = details.globalPosition.dx <= _edgeSwipeWidth;
    _edgeSwipeDistance = 0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_edgeSwipeActive) return;
    _edgeSwipeDistance += details.primaryDelta ?? 0;
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_edgeSwipeActive) return;
    final velocity = details.primaryVelocity ?? 0;
    final shouldPop =
        _edgeSwipeDistance >= _edgeSwipePopDistance || velocity > 450;
    _edgeSwipeActive = false;
    _edgeSwipeDistance = 0;
    if (shouldPop) {
      HapticFeedback.selectionClick();
      Navigator.of(context).maybePop();
    }
  }
}

class _TaskLogDrawerHandle extends StatelessWidget {
  const _TaskLogDrawerHandle();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showLogs(context),
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -120) _showLogs(context);
      },
      child: Tooltip(
        message: '日志',
        child: SizedBox(
          height: 44,
          child: Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withValues(alpha: 0.32),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showLogs(BuildContext context) {
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.58,
          minChildSize: 0.32,
          maxChildSize: 0.92,
          builder: (context, scrollController) {
            return SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                    child: Row(
                      children: [
                        Icon(
                          Icons.receipt_long_rounded,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '日志',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: LogsPanel(scrollController: scrollController),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _TaskAppBar extends StatelessWidget {
  final String taskId;
  final GlobalKey<_OutputViewState> outputViewKey;
  const _TaskAppBar({required this.taskId, required this.outputViewKey});

  @override
  Widget build(BuildContext context) {
    final taskListenable = context.read<NodeProvider>().taskListenable(taskId);
    return ValueListenableBuilder<TaskState?>(
      valueListenable: taskListenable,
      builder: (ctx, task, _) {
        final cs = Theme.of(ctx).colorScheme;
        final title = task?.displayTitle ?? '';
        final isRunning = task?.status == 'running';
        final hasMessages = (task?.messages.length ?? 0) > 0;
        return AppBar(
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          centerTitle: true,
          actions: [
            if (hasMessages)
              IconButton(
                icon: const Icon(Icons.format_list_bulleted_rounded),
                tooltip: '对话导航',
                onPressed: () => _showTurnNavigator(ctx, task!),
              ),
            if (isRunning && task != null)
              IconButton(
                icon: Icon(Icons.stop_circle, color: cs.error),
                tooltip: '紧急停止',
                onPressed: () => _confirmPanic(ctx, task),
              ),
          ],
        );
      },
    );
  }

  void _showTurnNavigator(BuildContext context, TaskState task) {
    final outputState = outputViewKey.currentState;
    if (outputState == null) return;
    final entries = outputState.getTurnEntries(task.messages);
    if (entries.isEmpty) return;

    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final cs = theme.colorScheme;
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: [
                    Icon(
                      Icons.format_list_bulleted_rounded,
                      size: 18,
                      color: cs.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '对话导航',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${entries.length} 条',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemBuilder: (context, i) {
                    final entry = entries[i];
                    final preview = entry.preview.length > 60
                        ? '${entry.preview.substring(0, 60)}…'
                        : entry.preview;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        entry.isUser
                            ? Icons.person_outline_rounded
                            : Icons.auto_awesome,
                        size: 18,
                        color: entry.isUser
                            ? cs.primary
                            : cs.secondary,
                      ),
                      title: Text(
                        preview.isEmpty ? '(空)' : preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      subtitle: entry.isUser
                          ? null
                          : Text(
                              '${entry.messageCount} 条消息',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                      trailing: Text(
                        '#${i + 1}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                      ),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        outputState.scrollToTurn(entry.index);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmPanic(BuildContext context, TaskState task) {
    final cs = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认终止'),
        content: Text('确定要强制终止任务「${task.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              context.read<NodeProvider>().sendPanic(
                task.nodeId,
                taskId: task.id,
              );
              Navigator.of(ctx).pop();
            },
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: const Text('终止'),
          ),
        ],
      ),
    );
  }
}

class _TaskInputBarWrapper extends StatelessWidget {
  final String taskId;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueListenable<String?> selectedModelListenable;
  final ValueChanged<String?> onModelChanged;
  final bool keyboardOpen;
  final VoidCallback onSend;
  final bool retryMode;
  final VoidCallback? onCancelRetry;

  const _TaskInputBarWrapper({
    required this.taskId,
    required this.controller,
    required this.focusNode,
    required this.selectedModelListenable,
    required this.onModelChanged,
    required this.keyboardOpen,
    required this.onSend,
    this.retryMode = false,
    this.onCancelRetry,
  });

  @override
  Widget build(BuildContext context) {
    final taskListenable = context.read<NodeProvider>().taskListenable(taskId);
    return ValueListenableBuilder<TaskState?>(
      valueListenable: taskListenable,
      builder: (ctx, task, _) {
        final isRunning = task?.status == 'running';
        return Selector<NodeProvider, NodeState?>(
          selector: (_, p) => p.getNode(task?.nodeId ?? ''),
          builder: (ctx, node, _) {
            final currentModel = task?.model ?? node?.piDefaultModel;
            return ValueListenableBuilder<String?>(
              valueListenable: selectedModelListenable,
              builder: (context, selectedModel, _) {
                return _InputBar(
                  controller: controller,
                  focusNode: focusNode,
                  node: node,
                  isRunning: isRunning,
                  selectedModel: selectedModel ?? currentModel,
                  onModelChanged: onModelChanged,
                  keyboardOpen: keyboardOpen,
                  onSend: onSend,
                  retryMode: retryMode,
                  onCancelRetry: onCancelRetry,
                );
              },
            );
          },
        );
      },
    );
  }
}

/// 输出流视图
class _OutputView extends StatefulWidget {
  final String taskId;
  const _OutputView({super.key, required this.taskId});

  @override
  State<_OutputView> createState() => _OutputViewState();
}

class _OutputViewState extends State<_OutputView> {
  final ScrollController _scrollController = ScrollController();
  int _lastMessageCount = 0;
  String _lastStreamingText = '';

  bool _isLoadingMore = false;
  bool _isPrepending = false;
  bool _hasMore = true;

  /// Count of messages loaded before the currently visible window.
  /// updated each time new history arrives.
  int _previousCount = 0;

  /// Scroll position snapshots for howcode-style delta correction on history load.
  double? _pendingScrollHeight;
  double? _pendingScrollOffset;

  /// Set of turn indices (0-based position among turns) that the user
  /// manually expanded.  The latest turn is always expanded; this set
  /// tracks additional user-expanded turns.
  final _expandedTurnKeys = <int>{};

  /// GlobalKeys for each turn widget, used by jump-to-turn navigation.
  final _turnGlobalKeys = <int, GlobalKey>{};

  /// When true, skip the 24K character cap for streaming content.
  bool _showFullStreaming = false;

  /// Stick-to-bottom state machine — mirrors howcode's shouldStickToBottom.
  bool _shouldStickToBottom = true;
  final _showScrollToBottom = ValueNotifier<bool>(false);
  bool _programmaticScroll = false;
  static const _autoScrollThreshold = 50.0;

  void scrollToTurn(int idx) {
    final key = _turnGlobalKeys[idx];
    if (key?.currentContext == null) return;
    _setShouldStickToBottom(false);
    Scrollable.ensureVisible(
      key!.currentContext!,
      alignment: 0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  List<_TurnEntry> getTurnEntries(List<PiSessionMessageInfo> messages) {
    final entries = <_TurnEntry>[];
    for (var idx = 0; idx < messages.length; idx++) {
      final msg = messages[idx];
      if (idx > 0 && msg.role != 'user' && messages[idx - 1].role != 'user') {
        continue;
      }
      if (msg.role == 'user') {
        entries.add(_TurnEntry(
          index: idx,
          isUser: true,
          preview: msg.text.replaceAll('\n', ' ').trim(),
          messageCount: 1,
        ));
      } else {
        var end = idx;
        while (end < messages.length && messages[end].role != 'user') {
          end++;
        }
        final group = messages.sublist(idx, end);
        final firstNonTool = group.firstWhere(
          (m) => m.role != 'toolResult',
          orElse: () => group.first,
        );
        entries.add(_TurnEntry(
          index: idx,
          isUser: false,
          preview: firstNonTool.structuredPreviewText
              .replaceAll('\n', ' ')
              .trim(),
          messageCount: group.length,
        ));
      }
    }
    return entries;
  }

  /// 缓存 provider 引用，避免在 dispose 中使用 context 查找
  /// （dispose 时 Element 已非 active，会导致
  /// "Looking up a deactivated widget's ancestor is unsafe"）。
  late final NodeProvider _provider;
  late final ValueListenable<TaskState?> _taskListenable;

  @override
  void initState() {
    super.initState();
    _provider = context.read<NodeProvider>();
    _taskListenable = _provider.taskListenable(widget.taskId);
    final task = _taskListenable.value;

    if (task != null) {
      _lastMessageCount = task.messages.length;
      _lastStreamingText = task.streamingText ?? '';
      _hasMore = task.nextBeforeIndex == null || task.nextBeforeIndex! > 0;
      _previousCount = (task.totalCount ?? 0) - task.messages.length;
      if (_previousCount < 0) _previousCount = 0;

      if (task.messages.isEmpty &&
          task.sessionPath != null &&
          task.sessionPath!.isNotEmpty) {
        _isLoadingMore = true;
        _isPrepending = true;
        _provider.requestSessionMessages(
          task.nodeId,
          task.id,
          task.sessionPath!,
          limit: 20,
        );
      }
    }

    _scrollController.addListener(_onScroll);
    _taskListenable.addListener(_onTaskChanged);
    _scrollToBottom(animate: false);
  }

  @override
  void dispose() {
    _taskListenable.removeListener(_onTaskChanged);
    _showScrollToBottom.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _loadEarlier() {
    final task = _taskListenable.value;
    if (task == null || !_hasMore || _isLoadingMore) return;
    if (task.sessionPath == null || task.sessionPath!.isEmpty) return;

    // Preserve scroll offset for howcode-style delta correction.
    if (_scrollController.hasClients) {
      _pendingScrollHeight = _scrollController.position.maxScrollExtent;
      _pendingScrollOffset = _scrollController.offset;
    }

    setState(() {
      _isLoadingMore = true;
      _isPrepending = true;
    });
    _provider.requestSessionMessages(
      task.nodeId,
      task.id,
      task.sessionPath!,
      limit: 20,
      beforeIndex: task.nextBeforeIndex,
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    // Do not update stick-to-bottom during programmatic scrolls.
    if (_programmaticScroll) return;

    final pixels = _scrollController.position.pixels;
    final max = _scrollController.position.maxScrollExtent;

    // Update stick-to-bottom flag — analogous to howcode's
    // shouldStickToBottomRef = isScrollContainerNearBottom(...).
    _setShouldStickToBottom((max - pixels) < _autoScrollThreshold);
  }

  void _setShouldStickToBottom(bool value) {
    if (_shouldStickToBottom == value) return;
    _shouldStickToBottom = value;
    _showScrollToBottom.value = !value;
  }

  void _onTaskChanged() {
    if (!mounted) return;
    final task = _taskListenable.value;
    if (task == null) return;

    _hasMore = task.nextBeforeIndex == null || task.nextBeforeIndex! > 0;

    bool shouldScroll = false;
    if (task.messages.length > _lastMessageCount) {
      if (_isPrepending) {
        if (_lastMessageCount > 0) {
          _adjustScrollAfterPrepend();
        } else {
          shouldScroll = true;
        }
        _previousCount = (task.totalCount ?? 0) - task.messages.length;
        if (_previousCount < 0) _previousCount = 0;
        setState(() {
          _isLoadingMore = false;
          _isPrepending = false;
        });
      } else {
        shouldScroll = true;
      }
      _lastMessageCount = task.messages.length;
    } else if (_isLoadingMore && task.messages.length == _lastMessageCount) {
      if (task.nextBeforeIndex == 0 ||
          (task.nextBeforeIndex != null && task.nextBeforeIndex! <= 0)) {
        setState(() {
          _isLoadingMore = false;
          _isPrepending = false;
          _hasMore = false;
        });
      }
    }

    final currentStreaming = task.streamingText ?? '';
    if (currentStreaming.length > _lastStreamingText.length) {
      shouldScroll = true;
    }
    _lastStreamingText = currentStreaming;

    // Only scroll if stick-to-bottom is engaged — if the user scrolled up
    // to read history, streaming deltas won't jump them back down.
    if (shouldScroll && _shouldStickToBottom) {
      _scrollToBottom();
    }
  }

  void _adjustScrollAfterPrepend() {
    final oldMaxScrollExtent = _pendingScrollHeight;
    final oldScrollOffset = _pendingScrollOffset;
    _pendingScrollHeight = null;
    _pendingScrollOffset = null;

    if (!_scrollController.hasClients || oldMaxScrollExtent == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final newMaxScrollExtent = _scrollController.position.maxScrollExtent;
      final difference = newMaxScrollExtent - oldMaxScrollExtent;
      if (difference > 0) {
        _scrollController.jumpTo((oldScrollOffset ?? 0) + difference);
      }
    });
  }

  void _scrollToBottom({bool animate = true}) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      final current = _scrollController.offset;
      if (max <= 0) return;

      // If user has scrolled up significantly, don't interrupt them
      // unless we are forcing (animate = false, used during streaming).
      if (max - current > _autoScrollThreshold && animate) {
        _setShouldStickToBottom(false);
        return;
      }

      _programmaticScroll = true;
      _scrollController.jumpTo(max);
      _setShouldStickToBottom(true);
      _programmaticScroll = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final canFold = _expandedTurnKeys.isNotEmpty;

    return Stack(
      children: [
        CustomScrollView(
          controller: _scrollController,
          slivers: [
            // Loading indicator while fetching.
            if (_isLoadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(top: 16, bottom: 8),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              ),
            // History divider — clickable row to load more.
            // Show whenever more messages exist, even before any history loads.
            if (!_isLoadingMore && _hasMore)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: Center(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: _loadEarlier,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: cs.surfaceContainerHighest.withValues(
                            alpha: 0.55,
                          ),
                        ),
                        child: Text(
                          _previousCount > 0
                              ? '$_previousCount 条更早的消息'
                              : '加载更早的消息',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver:
                  _TaskSliceBuilder<
                    (List<PiSessionMessageInfo>, String?, String?)
                  >(
                    taskId: widget.taskId,
                    selector: (task) => (
                      task?.messages ?? const <PiSessionMessageInfo>[],
                      task?.model,
                      task?.nodeId,
                    ),
                    shouldRebuild: (prev, next) =>
                        !identical(prev.$1, next.$1) ||
                        prev.$2 != next.$2 ||
                        prev.$3 != next.$3,
                    builder: (context, data) {
                      final (messages, taskModel, nodeId) = data;
                      return Selector<NodeProvider, String?>(
                        selector: (_, p) =>
                            p.getNode(nodeId ?? '')?.piDefaultModel,
                        builder: (context, defaultModel, _) {
                          final fallbackModel =
                              taskModel == null || taskModel.isEmpty
                              ? defaultModel
                              : taskModel;
                          return _HistoryMessagesSliver(
                            messages: messages,
                            fallbackModel: fallbackModel,
                            expandedTurnKeys: _expandedTurnKeys,
                            onExpand: (idx) => setState(() {
                              _expandedTurnKeys.add(idx);
                              _setShouldStickToBottom(false);
                            }),
                            turnGlobalKeys: _turnGlobalKeys,
                          );
                        },
                      );
                    },
                  ),
            ),
            SliverPadding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
              sliver: _TaskSliceBuilder<(List<MessagePart>, bool, String?)>(
                taskId: widget.taskId,
                selector: (task) => (
                  task?.streamingParts ?? const <MessagePart>[],
                  task?.status == 'running',
                  task?.statusLabel,
                ),
                shouldRebuild: (prev, next) =>
                    !identical(prev.$1, next.$1) ||
                    prev.$2 != next.$2 ||
                    prev.$3 != next.$3,
                builder: (context, data) {
                  final emptyColor = Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.62);
                  final streamingParts = data.$1;
                  final isRunning = data.$2;
                  final statusLabel = data.$3;
                  final hasStreamingParts = streamingParts.any(
                    (part) =>
                        (part.text ?? '').trim().isNotEmpty ||
                        part.type == MessagePartType.toolCall ||
                        part.type == MessagePartType.toolResult ||
                        part.type == MessagePartType.skill,
                  );
                  final hasContent = hasStreamingParts || statusLabel != null;
                  if (!hasContent) {
                    if (isRunning && _lastMessageCount == 0) {
                      return SliverToBoxAdapter(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 8),
                              Text(
                                '等待 Agent 输出...',
                                style: TextStyle(color: emptyColor),
                              ),
                            ],
                          ),
                        ),
                      );
                    } else if (!isRunning && _lastMessageCount == 0) {
                      return SliverToBoxAdapter(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.chat_bubble_outline,
                                size: 48,
                                color: emptyColor,
                              ),
                              const SizedBox(height: 8),
                              Text('暂无输出', style: TextStyle(color: emptyColor)),
                            ],
                          ),
                        ),
                      );
                    }
                    return const SliverToBoxAdapter(child: SizedBox.shrink());
                  }

                  return SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_streamingPartsTextLength(streamingParts) >
                              _maxRenderedStreamingChars)
                            _OutputTruncationNotice(
                              omittedChars:
                                  _streamingPartsTextLength(streamingParts) -
                                  _maxRenderedStreamingChars,
                              expanded: _showFullStreaming,
                              onToggle: () => setState(() {
                                _showFullStreaming = !_showFullStreaming;
                              }),
                            ),
                          if (hasStreamingParts)
                            ..._buildStreamingPartWidgets(
                              context,
                              _showFullStreaming
                                  ? streamingParts
                                  : _capStreamingPartsForRender(streamingParts),
                              isFinal: !isRunning,
                            ),
                          // Status label (compaction, retry, etc.)
                          if (statusLabel != null)
                            _StatusLabel(label: statusLabel),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),

        // Fold All button — only visible when at least one turn is manually expanded.
        if (canFold)
          Positioned(
            right: 12,
            bottom: 88,
            child: Material(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => setState(() {
                  _expandedTurnKeys.clear();
                  _setShouldStickToBottom(true);
                  _scrollToBottom(animate: false);
                }),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(
                    Icons.unfold_less_rounded,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),

        // Scroll-to-bottom button when not at bottom.
        ValueListenableBuilder<bool>(
          valueListenable: _showScrollToBottom,
          builder: (context, show, _) {
            if (!show) return const SizedBox.shrink();
            return Positioned(
              right: 12,
              bottom: 136,
              child: Material(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _scrollToBottom(animate: false),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      Icons.keyboard_double_arrow_down_rounded,
                      size: 18,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _TaskSliceBuilder<T> extends StatefulWidget {
  final String taskId;
  final T Function(TaskState? task) selector;
  final bool Function(T previous, T next)? shouldRebuild;
  final Widget Function(BuildContext context, T value) builder;

  const _TaskSliceBuilder({
    required this.taskId,
    required this.selector,
    required this.builder,
    this.shouldRebuild,
  });

  @override
  State<_TaskSliceBuilder<T>> createState() => _TaskSliceBuilderState<T>();
}

class _TaskSliceBuilderState<T> extends State<_TaskSliceBuilder<T>> {
  ValueListenable<TaskState?>? _listenable;
  late T _value;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _TaskSliceBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId != widget.taskId) {
      _detach();
      _attachIfNeeded();
      return;
    }
    _updateValue(rebuild: false);
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _value);
  }

  void _attachIfNeeded() {
    if (_listenable != null) return;
    _listenable = context.read<NodeProvider>().taskListenable(widget.taskId)
      ..addListener(_onTaskChanged);
    _value = widget.selector(_listenable!.value);
  }

  void _detach() {
    _listenable?.removeListener(_onTaskChanged);
    _listenable = null;
  }

  void _onTaskChanged() {
    _updateValue(rebuild: true);
  }

  void _updateValue({required bool rebuild}) {
    final listenable = _listenable;
    if (listenable == null) return;
    final next = widget.selector(listenable.value);
    if (!_hasChanged(_value, next)) return;
    if (rebuild && mounted) {
      setState(() => _value = next);
    } else {
      _value = next;
    }
  }

  bool _hasChanged(T previous, T next) {
    final shouldRebuild = widget.shouldRebuild;
    if (shouldRebuild != null) return shouldRebuild(previous, next);
    return previous != next;
  }
}

class _HistoryMessagesSliver extends StatelessWidget {
  final List<PiSessionMessageInfo> messages;
  final String? fallbackModel;
  final Set<int> expandedTurnKeys;
  final ValueChanged<int> onExpand;
  final Map<int, GlobalKey> turnGlobalKeys;

  const _HistoryMessagesSliver({
    required this.messages,
    required this.fallbackModel,
    required this.expandedTurnKeys,
    required this.onExpand,
    required this.turnGlobalKeys,
  });

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, idx) {
          final msg = messages[idx];

          // Skip non-start indices within a non-user group.
          if (idx > 0 &&
              msg.role != 'user' &&
              messages[idx - 1].role != 'user') {
            return const SizedBox.shrink();
          }

          final isUser = msg.role == 'user';
          if (isUser) {
            turnGlobalKeys.putIfAbsent(idx, () => GlobalKey());
            return _MessageItem(
              key: turnGlobalKeys[idx],
              message: msg,
              isUser: true,
              isFinal: true,
              modelName: fallbackModel,
              showHeader: true,
            );
          }

          // Collect consecutive non-user messages into a group.
          var end = idx;
          while (end < messages.length && messages[end].role != 'user') {
            end++;
          }
          final group = messages.sublist(idx, end);
          final turnKey = 'turn_$idx';

          // Find the index of the LAST non-user group.
          var lastNonUserIdx = -1;
          for (var i = messages.length - 1; i >= 0; i--) {
            if (messages[i].role != 'user') {
              while (i > 0 && messages[i - 1].role != 'user') {
                i--;
              }
              lastNonUserIdx = i;
              break;
            }
          }

          final isLatest = idx == lastNonUserIdx;
          final isExpanded = isLatest || expandedTurnKeys.contains(idx);

          turnGlobalKeys.putIfAbsent(idx, () => GlobalKey());
          if (isExpanded) {
            return _AgentTurnWidget(
              key: turnGlobalKeys[idx],
              messages: group,
              modelName: msg.model ?? fallbackModel,
            );
          }

          return _CollapsedTurnRow(
            key: turnGlobalKeys[idx],
            turnKey: turnKey,
            messages: group,
            modelName: msg.model ?? fallbackModel,
            onExpand: () => onExpand(idx),
          );
        },
        childCount: messages.length,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
      ),
    );
  }
}

/// 提取一条消息的可读纯文本：优先用 message.text，
/// 为空时回退到结构化 parts 里的正文 / 思考片段（跳过工具调用）。
String _messagePlainText(PiSessionMessageInfo m) {
  if (m.text.trim().isNotEmpty) return m.text.trim();
  return m.parts
      .where(
        (p) =>
            p.type == MessagePartType.text ||
            p.type == MessagePartType.thinking,
      )
      .map((p) => p.text ?? '')
      .where((t) => t.trim().isNotEmpty)
      .join('\n\n');
}

/// 复制消息文本到剪贴板，并给出触觉 + 视觉反馈。
void _copyMessage(BuildContext context, String text) {
  if (text.trim().isEmpty) return;
  HapticFeedback.mediumImpact();
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)),
  );
}

int _streamingPartsTextLength(List<MessagePart> parts) {
  var length = 0;
  for (final part in parts) {
    length += part.text?.length ?? 0;
  }
  return length;
}

/// Cap the total rendered text across text/thinking streaming parts to
/// [_maxRenderedStreamingChars], keeping the **tail** (most recent output).
/// Tool calls / results are passed through unchanged — only the long-form
/// text/thinking parts that dominate layout cost are truncated. This makes the
/// "已省略 Nk 字符" notice truthful and bounds the worst-case paragraph length
/// that `_LivePlainText` ever has to lay out.
///
/// Truncation is view-only: the provider still accumulates the full text, and
/// the finalized message (rendered via `PiMarkdown` once the turn completes)
/// shows everything.
List<MessagePart> _capStreamingPartsForRender(List<MessagePart> parts) {
  final total = _streamingPartsTextLength(parts);
  if (total <= _maxRenderedStreamingChars) return parts;

  var budget = _maxRenderedStreamingChars;
  // Walk in reverse so the tail is preserved; earlier text/thinking parts get
  // dropped first once the budget is exhausted.
  final result = <MessagePart>[];
  for (final part in parts.reversed) {
    final isTexty = part.type == MessagePartType.text ||
        part.type == MessagePartType.thinking;
    if (!isTexty) {
      result.add(part);
      continue;
    }
    final t = part.text ?? '';
    if (budget <= 0) continue; // drop older text parts entirely
    if (t.length <= budget) {
      result.add(part);
      budget -= t.length;
    } else {
      // Keep only the tail of this part; an ellipsis signals the cut.
      result.add(
        part.type == MessagePartType.thinking
            ? MessagePart.thinking('…${t.substring(t.length - budget)}')
            : MessagePart.text('…${t.substring(t.length - budget)}'),
      );
      budget = 0;
    }
  }
  return result.reversed.toList();
}

/// Streaming content rendered from protocol-structured parts.
List<Widget> _buildStreamingPartWidgets(
  BuildContext context,
  List<MessagePart> streamingParts, {
  bool isFinal = true,
}) {
  return _buildHistoryPartWidgets(context, streamingParts, isFinal: isFinal);
}

/// Transient status label (compaction, retry, etc.).
/// Render structured MessagePart list from historical messages.
/// No regex involved — parts come directly from Pi JSONL parsing.
List<Widget> _buildHistoryPartWidgets(
  BuildContext context,
  List<MessagePart> parts, {
  bool isFinal = true,
}) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final widgets = <Widget>[];

  int i = 0;
  while (i < parts.length) {
    final part = parts[i];

    switch (part.type) {
      case MessagePartType.text:
        if (part.text != null && part.text!.trim().isNotEmpty) {
          final style = theme.textTheme.bodyMedium?.copyWith(
            height: 1.6,
            color: cs.onSurface.withValues(alpha: 0.85),
          );
          widgets.add(
            RepaintBoundary(
              key: ValueKey('ht_$i'),
              child: !isFinal
                  ? _LivePlainText(text: part.text!, style: style)
                  : PiMarkdown(part.text!, style: style),
            ),
          );
        }
        break;
      case MessagePartType.thinking:
        if (part.text != null && part.text!.trim().isNotEmpty) {
          widgets.add(
            RepaintBoundary(
              key: ValueKey('hthink_$i'),
              child: _ThinkingBlock(text: part.text!, isLive: !isFinal),
            ),
          );
        }
        break;
      case MessagePartType.toolCall:
        widgets.add(
          _ToolChip(
            key: ValueKey('htc_$i'),
            toolName: part.name ?? '?',
            status: isFinal ? '成功' : null,
            isLoading: !isFinal,
          ),
        );
        break;
      case MessagePartType.toolResult:
        widgets.add(
          _ToolChip(
            key: ValueKey('htr_$i'),
            toolName: part.name ?? '?',
            status: part.status,
            content: part.text,
          ),
        );
        break;
      case MessagePartType.skill:
        widgets.add(
          _ToolChip(
            key: ValueKey('hsk_$i'),
            toolName: part.name ?? '?',
            status: 'skill',
          ),
        );
        break;
    }
    i++;
  }

  return widgets;
}

/// Streaming plain text rendered as line-separated chunks so that only the
/// last (still-growing) line re-lays-out on each delta. Earlier lines keep a
/// stable key + content and are reused by Flutter's element diffing, avoiding
/// the O(n) full-paragraph re-layout that a single growing `Text` would incur.
///
/// Without this, frame build time was measured (profile timeline) to jump from
/// ~3ms to ~17ms once streaming text grew past a few hundred chars, because
/// `RenderParagraph` re-measured the whole growing string every 80ms tick.
class _LivePlainText extends StatelessWidget {
  final String text;
  final TextStyle? style;

  const _LivePlainText({required this.text, required this.style});

  @override
  Widget build(BuildContext context) {
    // Fast path: short or single-line text — one Text, no Column overhead.
    if (text.length < 64 && !text.contains('\n')) {
      return SelectionArea(child: Text(text, style: style));
    }

    return SelectionArea(
      child: _LiveTextLines(text: text, style: style),
    );
  }
}

/// Renders `text` split on `\n` as one `Text` per line, each keyed by its line
/// index. A trailing newline yields an empty final line so the last visible
/// line stays stable when new content appends to it.
class _LiveTextLines extends StatelessWidget {
  final String text;
  final TextStyle? style;

  const _LiveTextLines({required this.text, required this.style});

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < lines.length; i++)
          Text(
            // Empty trailing line keeps a tiny strut so the column reserves no
            // spurious gap; content arrives on the next delta.
            lines[i],
            key: ValueKey('line_$i'),
            style: style,
          ),
      ],
    );
  }
}

class _StatusLabel extends StatelessWidget {
  final String label;
  const _StatusLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _OutputTruncationNotice extends StatelessWidget {
  final int omittedChars;
  final bool expanded;
  final VoidCallback onToggle;

  const _OutputTruncationNotice({
    required this.omittedChars,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '已省略较早的 ${omittedChars ~/ 1000}k 字符',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: onToggle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        expanded
                            ? Icons.unfold_less_rounded
                            : Icons.unfold_more_rounded,
                        size: 14,
                        color: cs.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        expanded ? '收起' : '展开全部',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (expanded) ...[
                const SizedBox(width: 8),
                Text(
                  '可能影响滚动性能',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Collapsed preview row for an agent turn group.
/// Shows model name + text preview + tool count in a single compact line.
/// Tapping expands the turn.
class _CollapsedTurnRow extends StatelessWidget {
  final String turnKey;
  final List<PiSessionMessageInfo> messages;
  final String? modelName;
  final VoidCallback onExpand;

  const _CollapsedTurnRow({
    super.key,
    required this.turnKey,
    required this.messages,
    this.modelName,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    // Preview: first assistant or non-tool text, truncated.
    final firstNonTool = messages.firstWhere(
      (m) => m.role != 'toolResult',
      orElse: () => messages.first,
    );
    final previewRaw = firstNonTool.structuredPreviewText
        .replaceAll('\n', ' ')
        .trim();
    final preview = previewRaw.length > 120
        ? '${previewRaw.substring(0, 120)}…'
        : previewRaw;

    final toolCount = messages
        .where(
          (m) =>
              m.role == 'toolResult' ||
              (m.parts.isNotEmpty &&
                  m.parts.any((p) => p.type == MessagePartType.toolCall)),
        )
        .length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: cs.surfaceContainerLow.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onExpand,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 8,
                  backgroundColor: cs.primaryContainer.withValues(alpha: 0.6),
                  child: Icon(
                    Icons.auto_awesome,
                    size: 10,
                    color: cs.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${messages.length} 条消息',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                              fontSize: 10,
                            ),
                          ),
                          if (toolCount > 0) ...[
                            Text(
                              ' · ',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                                fontSize: 10,
                              ),
                            ),
                            Text(
                              '$toolCount 个工具',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.35),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A grouped "turn" of consecutive non-user messages (assistant + toolResult + ...).
/// Shows one header (avatar + model name) for the whole group, Telegram-style.
class _AgentTurnWidget extends StatelessWidget {
  final List<PiSessionMessageInfo> messages;
  final String? modelName;

  const _AgentTurnWidget({super.key, required this.messages, this.modelName});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = modelName != null && modelName!.isNotEmpty
        ? modelName!
        : 'Pi Agent';

    return Container(
      margin: const EdgeInsets.only(top: 16, right: 16, bottom: 16, left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Single header for the whole turn
          Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  Icons.auto_awesome,
                  size: 14,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              // 复制整轮回复（避免与正文 SelectionArea 的长按手势冲突）。
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  final text = messages
                      .map(_messagePlainText)
                      .where((t) => t.isNotEmpty)
                      .join('\n\n');
                  _copyMessage(context, text);
                },
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.copy_rounded,
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Render each message in the turn — no individual headers
          for (int i = 0; i < messages.length; i++)
            _buildTurnMessage(context, messages[i], i),
        ],
      ),
    );
  }

  Widget _buildTurnMessage(
    BuildContext context,
    PiSessionMessageInfo message,
    int index,
  ) {
    final isToolResult = message.role == 'toolResult';
    final hasStructuredParts = message.parts.isNotEmpty;

    if (isToolResult) {
      if (hasStructuredParts) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: _buildHistoryPartWidgets(
              context,
              message.parts,
              isFinal: true,
            ),
          ),
        );
      }
      // Fallback: render raw text as markdown (old messages without parts)
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            PiMarkdown(
              message.text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.6,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      );
    }

    // Assistant message
    if (hasStructuredParts) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _buildHistoryPartWidgets(
          context,
          message.parts,
          isFinal: true,
        ),
      );
    }
    // Fallback: render raw text as markdown (old messages without parts)
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PiMarkdown(
          message.text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            height: 1.6,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.85),
          ),
        ),
      ],
    );
  }
}

class _MessageItem extends StatelessWidget {
  final PiSessionMessageInfo message;
  final bool isUser;
  final bool isFinal;
  final String? modelName;
  final bool showHeader;

  const _MessageItem({
    super.key,
    required this.message,
    required this.isUser,
    this.isFinal = true,
    this.modelName,
    this.showHeader = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(left: 64, bottom: 8, right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(12),
              topRight: Radius.circular(12),
              bottomLeft: Radius.circular(12),
              bottomRight: Radius.circular(2),
            ),
          ),
          child: PiMarkdown(
            message.text,
            inverted: true,
            dense: true,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onPrimary,
              height: 1.4,
            ),
          ),
        ),
      );
    } else {
      final isToolResult = message.role == 'toolResult';

      // Use structured parts when available (no regex parsing needed).
      final hasStructuredParts = message.parts.isNotEmpty;

      if (isToolResult) {
        if (hasStructuredParts) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 4, right: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: _buildHistoryPartWidgets(
                context,
                message.parts,
                isFinal: isFinal,
              ),
            ),
          );
        }
        // Fallback: render raw text as markdown (old messages without parts)
        return Padding(
          padding: const EdgeInsets.only(bottom: 4, left: 4, right: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              PiMarkdown(
                message.text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.6,
                  color: cs.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        );
      }

      final label = modelName != null && modelName!.isNotEmpty
          ? modelName!
          : 'Pi Agent';

      return Container(
        margin: EdgeInsets.only(
          top: showHeader ? 16 : 0,
          right: 16,
          bottom: showHeader ? 16 : 8,
          left: 4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showHeader) ...[
              Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(
                      Icons.auto_awesome,
                      size: 14,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (hasStructuredParts)
              ..._buildHistoryPartWidgets(
                context,
                message.parts,
                isFinal: isFinal,
              )
            else
              PiMarkdown(
                message.text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.6,
                  color: cs.onSurface.withValues(alpha: 0.85),
                ),
              ),
          ],
        ),
      );
    }
  }
}

class _ThinkingBlock extends StatefulWidget {
  final String text;
  final bool isLive;

  const _ThinkingBlock({required this.text, this.isLive = false});

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _expanded = false;

  /// First line or ~80 chars of thinking content for collapsed preview.
  String get _preview {
    final firstLine = widget.text
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (firstLine.length <= 80) return firstLine;
    return '${firstLine.substring(0, 80)}…';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!_expanded) {
      // Collapsed: label + text preview, matching howcode's
      // "Thinking — summary preview" pattern.
      return InkWell(
        onTap: () => setState(() => _expanded = true),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.psychology_outlined,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.5,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: RichText(
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: '思考',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.55,
                          ),
                          fontStyle: FontStyle.italic,
                          height: 1.4,
                        ),
                      ),
                      if (_preview.isNotEmpty)
                        TextSpan(
                          text: ' — $_preview',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.38),
                            fontStyle: FontStyle.italic,
                            height: 1.4,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Expanded: inline markdown with thinking text styling, no box
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = false),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.psychology,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.5,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '思考',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.5,
                    ),
                    fontStyle: FontStyle.italic,
                    height: 1.4,
                  ),
                ),
                Icon(
                  Icons.expand_less,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.4,
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 20, top: 2, bottom: 8),
          child: widget.isLive
              ? _LivePlainText(
                  text: widget.text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.75,
                    ),
                    fontStyle: FontStyle.italic,
                    height: 1.5,
                  ),
                )
              : PiMarkdown(
                  widget.text,
                  dense: true,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.75,
                    ),
                    fontStyle: FontStyle.italic,
                    height: 1.5,
                  ),
                ),
        ),
      ],
    );
  }
}

class _ToolChip extends StatefulWidget {
  final String toolName;
  final String? status;
  final String? content;
  final bool isLoading;

  const _ToolChip({
    super.key,
    required this.toolName,
    this.status,
    this.content,
    this.isLoading = false,
  });

  @override
  State<_ToolChip> createState() => _ToolChipState();
}

class _ToolChipState extends State<_ToolChip> {
  bool _expanded = false;

  IconData _getIconForTool(String name, String? status) {
    if (status == 'skill') return Icons.bolt;
    final n = name.toLowerCase();
    if (n.contains('shell') || n.contains('command') || n.contains('run')) {
      return Icons.terminal;
    }
    if (n.contains('read') ||
        n.contains('write') ||
        n.contains('file') ||
        n.contains('ls')) {
      return Icons.description;
    }
    if (n.contains('grep') || n.contains('search') || n.contains('find')) {
      return Icons.search;
    }
    if (n.contains('google') ||
        n.contains('web') ||
        n.contains('fetch') ||
        n.contains('browse')) {
      return Icons.language;
    }
    if (n.contains('git')) {
      return Icons.source;
    }
    if (n.contains('test') || n.contains('check')) {
      return Icons.fact_check;
    }
    return Icons.build;
  }

  /// Preview of result content (first line or ~60 chars).
  String get _resultPreview {
    final text = widget.content;
    if (text == null || text.isEmpty) return '';
    final firstLine = text
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (firstLine.length <= 60) return firstLine;
    return '${firstLine.substring(0, 60)}…';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = theme.appTokens;
    final isRunning = widget.isLoading;
    final isSkill = widget.status == 'skill';
    final isSuccess =
        widget.status == '成功' || widget.status == 'success' || isSkill;
    final isError = widget.status == '失败' || widget.status == 'error';
    final hasContent = widget.content != null && widget.content!.isNotEmpty;
    final canExpand = !isRunning && !isSkill && hasContent;

    final icon = _getIconForTool(widget.toolName, widget.status);
    final dimColor = cs.onSurfaceVariant.withValues(alpha: 0.45);
    final preview = _resultPreview;

    // Status badge widget.
    final badge = isRunning
        ? SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: cs.primary.withValues(alpha: 0.6),
            ),
          )
        : isSuccess
        ? Icon(
            Icons.check_circle_outline,
            size: 10,
            color: tokens.statusRunning.withValues(alpha: 0.7),
          )
        : isError
        ? Icon(
            Icons.error_outline,
            size: 10,
            color: cs.error.withValues(alpha: 0.65),
          )
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: canExpand
              ? () => setState(() => _expanded = !_expanded)
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isRunning)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: cs.primary.withValues(alpha: 0.5),
                    ),
                  )
                else
                  Icon(
                    isSuccess ? icon : Icons.error_outline,
                    size: 13,
                    color: isSuccess
                        ? dimColor
                        : cs.error.withValues(alpha: 0.6),
                  ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    isRunning ? '正在使用 ${widget.toolName}...' : widget.toolName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      color: isRunning
                          ? cs.primary.withValues(alpha: 0.5)
                          : dimColor,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
                if (preview.isNotEmpty && !_expanded) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    flex: 2,
                    child: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ],
                if (badge != null) ...[const SizedBox(width: 5), badge],
                if (canExpand) ...[
                  const SizedBox(width: 2),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 13,
                    color: dimColor.withValues(alpha: 0.6),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_expanded && hasContent)
          Padding(
            padding: const EdgeInsets.only(left: 18, top: 2, bottom: 4),
            child: PiMarkdown(
              widget.content!,
              dense: true,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11,
                fontFamily: 'monospace',
                fontFamilyFallback: const [
                  'Courier New',
                  'PingFang SC',
                  'Microsoft YaHei',
                  'sans-serif',
                ],
                color: cs.onSurfaceVariant.withValues(alpha: 0.55),
              ),
            ),
          ),
      ],
    );
  }
}

/// 底部输入栏
class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final NodeState? node;
  final bool isRunning;
  final String? selectedModel;
  final ValueChanged<String?> onModelChanged;
  final bool keyboardOpen;
  final VoidCallback onSend;
  final bool retryMode;
  final VoidCallback? onCancelRetry;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.node,
    required this.isRunning,
    this.selectedModel,
    required this.onModelChanged,
    required this.keyboardOpen,
    required this.onSend,
    this.retryMode = false,
    this.onCancelRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final models = node?.piModels ?? const <PiModelInfo>[];
    final actions = _composerActions(context, models);
    final mediaQuery = MediaQuery.of(context);

    return Container(
      key: const ValueKey('task-detail-input-bar'),
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 10,
        bottom: keyboardOpen ? 10 : mediaQuery.padding.bottom + 10,
      ),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.45)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (retryMode) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: cs.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.refresh_rounded, size: 14, color: cs.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '重试模式 — 上次消息已预填',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.error,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: onCancelRetry,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: cs.error.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
          ],
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: actions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final action = actions[index];
                if (action.isModelPicker) {
                  return _ModelPickerChip(
                    models: models,
                    selectedModel: selectedModel,
                    onModelChanged: onModelChanged,
                  );
                }
                return _ComposerChip(
                  label: action.label,
                  icon: action.icon,
                  selected: false,
                  tooltip: action.tooltip,
                  onTap: action.onTap,
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(minHeight: 62),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Row(
              children: [
                const SizedBox(width: 20),
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: isRunning ? '中途纠正方向...' : '继续这个会话...',
                      hintStyle: theme.textTheme.titleMedium?.copyWith(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.42),
                        fontWeight: FontWeight.w500,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    final hasText = value.text.trim().isNotEmpty;
                    return Tooltip(
                      message: '发送',
                      child: IconButton(
                        onPressed: hasText ? onSend : null,
                        icon: const Icon(Icons.send_rounded),
                        color: hasText ? cs.primary : cs.onSurfaceVariant,
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<_ComposerAction> _composerActions(
    BuildContext context,
    List<PiModelInfo> models,
  ) {
    final commands = node?.piSlashCommands ?? const <PiSlashCommandInfo>[];
    final actions = <_ComposerAction>[
      // 模型选择器占位（由 itemBuilder 特殊处理）
      _ComposerAction.modelPicker(),
      _ComposerAction(
        label: isRunning ? '纠偏' : '继续',
        icon: isRunning ? Icons.alt_route_rounded : Icons.add_comment_outlined,
        tooltip: isRunning ? '当前发送会立即纠正运行中的 Agent' : '当前发送会作为会话后续消息',
        onTap: () => _insertPrompt(''),
      ),
    ];

    actions.add(
      _ComposerAction(
        label: '命令',
        icon: Icons.terminal,
        onTap: () => _showCommandSheet(context, commands),
      ),
    );

    return actions;
  }

  String _commandTitle(PiSlashCommandInfo command) {
    final source = command.source.toLowerCase();
    final prefix = source == 'skill' ? 'SKILL ' : '/';
    return '$prefix${command.name}';
  }

  String _commandInsertion(PiSlashCommandInfo command) {
    final source = command.source.toLowerCase();
    return source == 'skill'
        ? '<skill>${command.name}</skill> '
        : '/${command.name} ';
  }

  void _showCommandSheet(
    BuildContext context,
    List<PiSlashCommandInfo> commands,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return _DetailCommandSheet(
          commands: commands,
          commandTitle: _commandTitle,
          commandInsertion: _commandInsertion,
          onInsertPrompt: _insertPrompt,
        );
      },
    );
  }

  void _insertPrompt(String insertion) {
    if (insertion.isEmpty) {
      focusNode.requestFocus();
      return;
    }
    final value = controller.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final nextText = text.replaceRange(start, end, insertion);
    final cursor = start + insertion.length;
    controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: cursor),
    );
    focusNode.requestFocus();
  }
}

class _ComposerAction {
  final String label;
  final bool isModelPicker;
  final IconData? icon;
  final String? tooltip;
  final VoidCallback onTap;

  const _ComposerAction({
    required this.label,
    this.isModelPicker = false,
    this.icon,
    this.tooltip,
    required this.onTap,
  });

  factory _ComposerAction.modelPicker() =>
      _ComposerAction(label: '', isModelPicker: true, onTap: () {});
}

class _ModelPickerChip extends StatelessWidget {
  final List<PiModelInfo> models;
  final String? selectedModel;
  final ValueChanged<String?> onModelChanged;

  const _ModelPickerChip({
    required this.models,
    required this.selectedModel,
    required this.onModelChanged,
  });

  String _shortLabel(String modelId) {
    final last = modelId.split('/').last;
    return last.length > 16 ? '${last.substring(0, 15)}\u2026' : last;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final label = selectedModel != null ? _shortLabel(selectedModel!) : '模型';
    final hasSelection = selectedModel != null;

    return Material(
      color: hasSelection
          ? cs.primaryContainer.withValues(alpha: 0.45)
          : cs.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () async {
          if (models.isEmpty) return;
          final box = context.findRenderObject() as RenderBox;
          final offset = box.localToGlobal(Offset.zero);
          final result = await showMenu<String>(
            context: context,
            position: RelativeRect.fromLTRB(
              offset.dx,
              offset.dy - 8,
              offset.dx + box.size.width,
              offset.dy,
            ),
            items: [
              if (hasSelection)
                PopupMenuItem<String>(
                  value: '__reset__',
                  child: Row(
                    children: [
                      Icon(
                        Icons.restart_alt,
                        size: 16,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text('使用默认模型', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ...models.map(
                (m) => PopupMenuItem<String>(
                  value: m.id,
                  child: Row(
                    children: [
                      Icon(
                        m.id == selectedModel
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 16,
                        color: m.id == selectedModel
                            ? cs.primary
                            : cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          m.name.isNotEmpty ? m.name : m.model,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: m.id == selectedModel ? cs.primary : null,
                            fontWeight: m.id == selectedModel
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
          if (result == null) return;
          onModelChanged(result == '__reset__' ? null : result);
        },
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: hasSelection
                  ? cs.primary.withValues(alpha: 0.5)
                  : cs.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.tune,
                size: 14,
                color: hasSelection ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: hasSelection ? cs.primary : cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 3),
              Icon(
                Icons.expand_less,
                size: 14,
                color: hasSelection
                    ? cs.primary.withValues(alpha: 0.7)
                    : cs.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComposerChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final String? tooltip;
  final VoidCallback onTap;

  const _ComposerChip({
    required this.label,
    this.icon,
    required this.selected,
    this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final foreground = selected ? cs.primary : cs.onSurface;
    final background = selected
        ? cs.primaryContainer.withValues(alpha: 0.45)
        : cs.surface;

    final chip = Material(
      color: background,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: foreground),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (tooltip == null) return chip;
    return Tooltip(message: tooltip!, child: chip);
  }
}

/// 命令选择面板（带搜索过滤）。
class _DetailCommandSheet extends StatefulWidget {
  final List<PiSlashCommandInfo> commands;
  final String Function(PiSlashCommandInfo) commandTitle;
  final String Function(PiSlashCommandInfo) commandInsertion;
  final ValueChanged<String> onInsertPrompt;

  const _DetailCommandSheet({
    required this.commands,
    required this.commandTitle,
    required this.commandInsertion,
    required this.onInsertPrompt,
  });

  @override
  State<_DetailCommandSheet> createState() => _DetailCommandSheetState();
}

class _DetailCommandSheetState extends State<_DetailCommandSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.commands
        : widget.commands
              .where(
                (c) =>
                    c.name.toLowerCase().contains(q) ||
                    c.description.toLowerCase().contains(q),
              )
              .toList();

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.56,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Row(
                children: [
                  Icon(Icons.terminal, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(
                    '选择命令',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            if (widget.commands.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    hintText: '搜索命令…',
                    isDense: true,
                    filled: true,
                    fillColor: cs.surfaceContainerLow,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            Divider(height: 1, color: cs.outlineVariant),
            Expanded(
              child: widget.commands.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [
                        _CommandListTile(
                          title: '/',
                          description: '插入 slash command 前缀',
                          icon: Icons.terminal,
                          onTap: () {
                            Navigator.of(context).pop();
                            widget.onInsertPrompt('/');
                          },
                        ),
                        _CommandListTile(
                          title: 'SKILL',
                          description: '插入 skill 标签模板',
                          icon: Icons.bolt_outlined,
                          onTap: () {
                            Navigator.of(context).pop();
                            widget.onInsertPrompt('<skill></skill> ');
                          },
                        ),
                      ],
                    )
                  : filtered.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的命令',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        indent: 56,
                        color: cs.outlineVariant.withValues(alpha: 0.55),
                      ),
                      itemBuilder: (context, index) {
                        final command = filtered[index];
                        final isSkill = command.source.toLowerCase() == 'skill';
                        final commandDescription = command.description.trim();
                        final fallbackDescription = isSkill
                            ? '插入 skill 命令'
                            : '插入 slash command';
                        final description = commandDescription.isEmpty
                            ? fallbackDescription
                            : commandDescription;

                        return _CommandListTile(
                          title: widget.commandTitle(command),
                          description: description,
                          icon: isSkill ? Icons.bolt_outlined : Icons.terminal,
                          onTap: () {
                            Navigator.of(context).pop();
                            widget.onInsertPrompt(
                              widget.commandInsertion(command),
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandListTile extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final VoidCallback onTap;

  const _CommandListTile({
    required this.title,
    required this.description,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return ListTile(
      leading: Icon(icon, color: cs.primary),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        description,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      onTap: onTap,
    );
  }
}

class _TaskErrorCard extends StatelessWidget {
  final TaskState task;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  const _TaskErrorCard({
    required this.task,
    required this.onRetry,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final errorText = (task.streamingText ?? '').trim();
    final displayError = errorText.isEmpty
        ? '任务执行过程中发生错误'
        : errorText.length > 200
            ? '${errorText.substring(0, 200)}…'
            : errorText;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: cs.error, width: 3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, size: 18, color: cs.error),
                const SizedBox(width: 8),
                Text(
                  '任务失败',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: cs.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: onDismiss,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              displayError,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.7),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('重试'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    textStyle: theme.textTheme.labelMedium,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TurnEntry {
  final int index;
  final bool isUser;
  final String preview;
  final int messageCount;

  const _TurnEntry({
    required this.index,
    required this.isUser,
    required this.preview,
    required this.messageCount,
  });
}
