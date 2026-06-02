import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../models/node_state.dart';
import '../providers/node_provider.dart';
import '../widgets/pi_markdown.dart';
import '../widgets/task_status_bar.dart';

/// 任务详情页 — 展示完整输出流 + Steering/Follow-up 输入
const int _maxRenderedStreamingChars = 24000;

class TaskDetailScreen extends StatefulWidget {
  final String taskId;

  const TaskDetailScreen({super.key, required this.taskId});

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  final _inputController = TextEditingController();
  final _inputFocusNode = FocusNode();
  // Keep composer-only state out of the page rebuild path.
  final _isSteer = ValueNotifier<bool>(false); // false = followUp, true = steer
  final _selectedModel = ValueNotifier<String?>(null); // null = node default

  @override
  void dispose() {
    _isSteer.dispose();
    _selectedModel.dispose();
    _inputController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    final provider = context.read<NodeProvider>();
    if (_isSteer.value) {
      provider.sendSteer(widget.taskId, text, model: _selectedModel.value);
    } else {
      provider.sendFollowUp(widget.taskId, text, model: _selectedModel.value);
    }
    _inputController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final taskExists = context.select<NodeProvider, bool>(
      (p) => p.getTask(widget.taskId) != null,
    );

    if (!taskExists) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务不存在')),
        body: const Center(child: Text('任务未找到')),
      );
    }

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: _TaskAppBar(taskId: widget.taskId),
      ),
      body: Column(
        children: [
          TaskStatusBar(taskId: widget.taskId),
          Expanded(child: _OutputView(taskId: widget.taskId)),
          _TaskInputBarWrapper(
            taskId: widget.taskId,
            controller: _inputController,
            focusNode: _inputFocusNode,
            isSteerListenable: _isSteer,
            selectedModelListenable: _selectedModel,
            onSteerToggle: () => _isSteer.value = !_isSteer.value,
            onModelChanged: (m) => _selectedModel.value = m,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

class _TaskAppBar extends StatelessWidget {
  final String taskId;
  const _TaskAppBar({required this.taskId});

  @override
  Widget build(BuildContext context) {
    return Selector<NodeProvider, (String, bool, TaskState?)>(
      selector: (ctx, p) {
        final t = p.getTask(taskId);
        return (t?.displayTitle ?? '', t?.status == 'running', t);
      },
      builder: (ctx, data, _) {
        final (title, isRunning, task) = data;
        return AppBar(
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          centerTitle: true,
          actions: [
            if (isRunning && task != null)
              IconButton(
                icon: const Icon(Icons.stop_circle, color: Colors.red),
                tooltip: '紧急停止',
                onPressed: () => _confirmPanic(ctx, task),
              ),
          ],
        );
      },
    );
  }

  void _confirmPanic(BuildContext context, TaskState task) {
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
            style: TextButton.styleFrom(foregroundColor: Colors.red),
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
  final ValueListenable<bool> isSteerListenable;
  final ValueListenable<String?> selectedModelListenable;
  final VoidCallback onSteerToggle;
  final ValueChanged<String?> onModelChanged;
  final VoidCallback onSend;

  const _TaskInputBarWrapper({
    required this.taskId,
    required this.controller,
    required this.focusNode,
    required this.isSteerListenable,
    required this.selectedModelListenable,
    required this.onSteerToggle,
    required this.onModelChanged,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<NodeProvider, (bool, bool, NodeState?, String?)>(
      selector: (ctx, p) {
        final t = p.getTask(taskId);
        final isHistory = t?.status == 'history';
        final isRunning = t?.status == 'running';
        NodeState? node;
        if (t != null) {
          for (final n in p.nodes) {
            if (n.nodeId == t.nodeId) {
              node = n;
              break;
            }
          }
        }
        // 当前任务实际使用的模型（来自最新消息或 task.model）
        final currentModel = t?.model ?? node?.piDefaultModel;
        return (isHistory, isRunning, node, currentModel);
      },
      builder: (ctx, data, _) {
        final (isHistory, isRunning, node, currentModel) = data;

        return ValueListenableBuilder<bool>(
          valueListenable: isSteerListenable,
          builder: (context, isSteer, _) {
            return ValueListenableBuilder<String?>(
              valueListenable: selectedModelListenable,
              builder: (context, selectedModel, _) {
                return _InputBar(
                  controller: controller,
                  focusNode: focusNode,
                  node: node,
                  isSteer: isSteer,
                  isRunning: isRunning,
                  selectedModel: selectedModel ?? currentModel,
                  onSteerToggle: onSteerToggle,
                  onModelChanged: onModelChanged,
                  onSend: onSend,
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
  const _OutputView({required this.taskId});

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

  /// Incremented whenever _expandedTurnKeys changes, used to trigger
  /// Selector rebuilds when the user toggles a turn.
  int _collapseVersion = 0;

  /// Stick-to-bottom state machine — mirrors howcode's shouldStickToBottom.
  bool _shouldStickToBottom = true;
  bool _programmaticScroll = false;
  static const _autoScrollThreshold = 50.0;

  /// 缓存 provider 引用，避免在 dispose 中使用 context 查找
  /// （dispose 时 Element 已非 active，会导致
  /// "Looking up a deactivated widget's ancestor is unsafe"）。
  late final NodeProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = context.read<NodeProvider>();
    final task = _provider.getTask(widget.taskId);

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
    _provider.addListener(_onProviderChanged);
    _scrollToBottom(animate: false);
  }

  @override
  void dispose() {
    _provider.removeListener(_onProviderChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _loadEarlier() {
    final task = _provider.getTask(widget.taskId);
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
    final wasStick = _shouldStickToBottom;
    _shouldStickToBottom = (max - pixels) < _autoScrollThreshold;
    if (_shouldStickToBottom != wasStick) {
      // Rebuild so the scroll-to-bottom button appears/disappears.
      // Provider's Selector will skip since messages haven't changed.
      setState(() {});
    }
  }

  void _onProviderChanged() {
    if (!mounted) return;
    final task = _provider.getTask(widget.taskId);
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
        _shouldStickToBottom = false;
        return;
      }

      _programmaticScroll = true;
      _scrollController.jumpTo(max);
      _shouldStickToBottom = true;
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
                              ? '$_previousCount earlier messages'
                              : 'Load earlier messages',
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
                  Selector<
                    NodeProvider,
                    (List<PiSessionMessageInfo>, String?, int)
                  >(
                    selector: (ctx, p) {
                      final task = p.getTask(widget.taskId);
                      // task-level fallback model（用于没有 per-message model 的情况）
                      String? fallbackModel = task?.model;
                      if (fallbackModel == null || fallbackModel.isEmpty) {
                        final node = p.getNode(task?.nodeId ?? '');
                        fallbackModel = node?.piDefaultModel;
                      }
                      return (
                        task?.messages ?? const [],
                        fallbackModel,
                        _collapseVersion,
                      );
                    },
                    shouldRebuild: (prev, next) =>
                        prev.$1.length != next.$1.length ||
                        prev.$2 != next.$2 ||
                        prev.$3 != next.$3,
                    builder: (context, data, _) {
                      final (messages, fallbackModel, collapseVer) = data;
                      if (messages.isEmpty) {
                        return const SliverToBoxAdapter(
                          child: SizedBox.shrink(),
                        );
                      }
                      return SliverList(
                        delegate: SliverChildBuilderDelegate((context, idx) {
                          final msg = messages[idx];

                          // Skip non-start indices within a non-user group.
                          if (idx > 0 &&
                              msg.role != 'user' &&
                              messages[idx - 1].role != 'user') {
                            return const SizedBox.shrink();
                          }

                          final isUser = msg.role == 'user';
                          if (isUser) {
                            return _MessageItem(
                              key: ValueKey('msg_$idx'),
                              message: msg,
                              isUser: true,
                              isFinal: true,
                              modelName: fallbackModel,
                              showHeader: true,
                            );
                          }

                          // Collect consecutive non-user messages into a group.
                          int end = idx;
                          while (end < messages.length &&
                              messages[end].role != 'user') {
                            end++;
                          }
                          final group = messages.sublist(idx, end);
                          final turnKey = 'turn_$idx';

                          // Find the index of the LAST non-user group.
                          int lastNonUserIdx = -1;
                          for (int i = messages.length - 1; i >= 0; i--) {
                            if (messages[i].role != 'user') {
                              while (i > 0 && messages[i - 1].role != 'user') {
                                i--;
                              }
                              lastNonUserIdx = i;
                              break;
                            }
                          }

                          final isLatest = idx == lastNonUserIdx;
                          final isExpanded =
                              isLatest || _expandedTurnKeys.contains(idx);

                          if (isExpanded) {
                            return _AgentTurnWidget(
                              key: ValueKey(turnKey),
                              messages: group,
                              modelName: msg.model ?? fallbackModel,
                            );
                          }

                          return _CollapsedTurnRow(
                            key: ValueKey('collapsed_$idx'),
                            turnKey: turnKey,
                            messages: group,
                            modelName: msg.model ?? fallbackModel,
                            onExpand: () => setState(() {
                              _expandedTurnKeys.add(idx);
                              _collapseVersion++;
                              _shouldStickToBottom = false;
                            }),
                          );
                        }, childCount: messages.length),
                      );
                    },
                  ),
            ),
            SliverPadding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
              sliver:
                  Selector<
                    NodeProvider,
                    (List<MessagePart>, bool, List<StreamingToolEvent>, String?)
                  >(
                    selector: (ctx, p) {
                      final t = p.getTask(widget.taskId);
                      return (
                        t?.streamingParts ?? const [],
                        t?.status == 'running',
                        t?.toolEvents ?? const [],
                        t?.statusLabel,
                      );
                    },
                    builder: (context, data, _) {
                      final streamingParts = data.$1;
                      final isRunning = data.$2;
                      final toolEvents = data.$3;
                      final statusLabel = data.$4;
                      final hasStreamingText = streamingParts.any(
                        (part) => (part.text ?? '').trim().isNotEmpty,
                      );
                      final hasContent =
                          hasStreamingText ||
                          toolEvents.isNotEmpty ||
                          statusLabel != null;
                      if (!hasContent) {
                        if (isRunning && _lastMessageCount == 0) {
                          return const SliverToBoxAdapter(
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(),
                                  SizedBox(height: 8),
                                  Text(
                                    '等待 Agent 输出...',
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                ],
                              ),
                            ),
                          );
                        } else if (!isRunning && _lastMessageCount == 0) {
                          return const SliverToBoxAdapter(
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.chat_bubble_outline,
                                    size: 48,
                                    color: Colors.grey,
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    '暂无输出',
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }
                        return const SliverToBoxAdapter(
                          child: SizedBox.shrink(),
                        );
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
                                      _streamingPartsTextLength(
                                        streamingParts,
                                      ) -
                                      _maxRenderedStreamingChars,
                                ),
                              if (hasStreamingText)
                                ..._buildStreamingPartWidgets(
                                  context,
                                  streamingParts,
                                  isFinal: !isRunning,
                                ),
                              // Structured tool events
                              if (toolEvents.isNotEmpty)
                                _buildStreamingToolChips(
                                  context,
                                  toolEvents,
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
                  _collapseVersion++;
                  _shouldStickToBottom = true;
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
        if (!_shouldStickToBottom)
          Positioned(
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
          ),
      ],
    );
  }
}

int _streamingPartsTextLength(List<MessagePart> parts) {
  var length = 0;
  for (final part in parts) {
    length += part.text?.length ?? 0;
  }
  return length;
}

/// Streaming content rendered from protocol-structured parts.
List<Widget> _buildStreamingPartWidgets(
  BuildContext context,
  List<MessagePart> streamingParts, {
  bool isFinal = true,
}) {
  return _buildHistoryPartWidgets(context, streamingParts, isFinal: isFinal);
}

/// Render structured tool events as chips.
///
/// Merges call+result pairs into a single chip so the UI shows one
/// entry per tool execution, matching pi-tui's single-line display.
Widget _buildStreamingToolChips(
  BuildContext context,
  List<StreamingToolEvent> toolEvents, {
  bool isFinal = true,
}) {
  final chips = <Widget>[];
  final consumed = <int>{};

  for (int i = 0; i < toolEvents.length; i++) {
    if (consumed.contains(i)) continue;
    final ev = toolEvents[i];

    if (ev.isResult) {
      // Standalone result — render directly.
      chips.add(
        _ToolChip(
          key: ValueKey('tr_$i'),
          toolName: ev.name,
          status: ev.isError ? '失败' : '成功',
          content: ev.resultText,
        ),
      );
      consumed.add(i);
    } else {
      // Call event — look for a matching result anywhere later.
      int? resultIdx;
      for (int j = i + 1; j < toolEvents.length; j++) {
        if (toolEvents[j].isResult && toolEvents[j].name == ev.name) {
          resultIdx = j;
          break;
        }
      }

      if (resultIdx != null) {
        final res = toolEvents[resultIdx];
        consumed.add(resultIdx);
        chips.add(
          _ToolChip(
            key: ValueKey('tc_${i}_r'),
            toolName: ev.name,
            status: res.isError ? '失败' : '成功',
            content: res.resultText,
          ),
        );
      } else {
        chips.add(
          _ToolChip(
            key: ValueKey('tc_$i'),
            toolName: ev.name,
            status: null,
            isLoading: !isFinal,
          ),
        );
      }
    }
  }

  if (chips.isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: _ToolGroupPanel(
      key: ValueKey('streaming_tools_${toolEvents.length}_$isFinal'),
      chips: chips,
      forceExpanded: !isFinal,
    ),
  );
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
          widgets.add(
            RepaintBoundary(
              key: ValueKey('ht_$i'),
              child: PiMarkdown(
                part.text!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.6,
                  color: cs.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
          );
        }
        break;
      case MessagePartType.thinking:
        if (part.text != null && part.text!.trim().isNotEmpty) {
          widgets.add(
            RepaintBoundary(
              key: ValueKey('hthink_$i'),
              child: _ThinkingBlock(text: part.text!),
            ),
          );
        }
        break;
      case MessagePartType.toolCall:
        widgets.add(
          _ToolChip(
            key: ValueKey('htc_$i'),
            toolName: part.name ?? '?',
            status: '成功',
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

  const _OutputTruncationNotice({required this.omittedChars});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        '已省略较早的 ${omittedChars ~/ 1000}k 字符，避免浏览器长帧；完整历史可从会话消息继续向上加载。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
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
                      if (toolCount > 0)
                        Text(
                          toolCount == 1 ? '1 tool' : '$toolCount tools',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                            fontSize: 10,
                          ),
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
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: PiMarkdown(
            message.text,
            inverted: true,
            dense: true,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white,
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
  const _ThinkingBlock({required this.text});

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
          child: PiMarkdown(
            widget.text,
            dense: true,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
              fontStyle: FontStyle.italic,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

/// Collapsible tool-call group panel — howcode-style "Tool calls (N)".
/// Wraps a list of _ToolChip children in a single expandable container.
class _ToolGroupPanel extends StatefulWidget {
  final List<Widget> chips;
  final bool forceExpanded;

  const _ToolGroupPanel({
    super.key,
    required this.chips,
    this.forceExpanded = false,
  });

  @override
  State<_ToolGroupPanel> createState() => _ToolGroupPanelState();
}

class _ToolGroupPanelState extends State<_ToolGroupPanel> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.forceExpanded;
  }

  @override
  void didUpdateWidget(covariant _ToolGroupPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.forceExpanded && !_expanded) {
      setState(() => _expanded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final count = widget.chips.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: widget.forceExpanded
              ? null
              : () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.build_outlined,
                  size: 13,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.35),
                ),
                const SizedBox(width: 6),
                Text(
                  count == 1 ? '1 tool' : '$count tools',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (!widget.forceExpanded) ...[
                  const SizedBox(width: 2),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 13,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.35),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: widget.chips,
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
            color: Colors.green.withValues(alpha: 0.7),
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
  final bool isSteer;
  final bool isRunning;
  final String? selectedModel;
  final VoidCallback onSteerToggle;
  final ValueChanged<String?> onModelChanged;
  final VoidCallback onSend;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.node,
    required this.isSteer,
    required this.isRunning,
    this.selectedModel,
    required this.onSteerToggle,
    required this.onModelChanged,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final models = node?.piModels ?? const <PiModelInfo>[];
    final actions = _composerActions(context, models);

    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 10,
        bottom: MediaQuery.of(context).padding.bottom + 10,
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
                  selected: action.selected,
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
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
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
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: isRunning
                          ? (isSteer ? '中途纠正方向...' : '发消息...')
                          : '发消息...',
                      hintStyle: theme.textTheme.titleMedium?.copyWith(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.42),
                        fontWeight: FontWeight.w500,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onSubmitted: (_) => onSend(),
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
        label: isRunning ? (isSteer ? '调校' : '追加') : '追加',
        selected: isRunning && isSteer,
        onTap: isRunning ? onSteerToggle : () => _insertPrompt(''),
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
        final theme = Theme.of(sheetContext);
        final cs = theme.colorScheme;
        final items = commands;

        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.56,
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
                Divider(height: 1, color: cs.outlineVariant),
                Expanded(
                  child: items.isEmpty
                      ? ListView(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          children: [
                            _CommandListTile(
                              title: '/',
                              description: '插入 slash command 前缀',
                              icon: Icons.terminal,
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                _insertPrompt('/');
                              },
                            ),
                            _CommandListTile(
                              title: 'SKILL',
                              description: '插入 skill 标签模板',
                              icon: Icons.bolt_outlined,
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                _insertPrompt('<skill></skill> ');
                              },
                            ),
                          ],
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: items.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            indent: 56,
                            color: cs.outlineVariant.withValues(alpha: 0.55),
                          ),
                          itemBuilder: (context, index) {
                            final command = items[index];
                            final isSkill =
                                command.source.toLowerCase() == 'skill';
                            final commandDescription = command.description
                                .trim();
                            final fallbackDescription = isSkill
                                ? '插入 skill 命令'
                                : '插入 slash command';
                            final description = commandDescription.isEmpty
                                ? fallbackDescription
                                : commandDescription;

                            return _CommandListTile(
                              title: _commandTitle(command),
                              description: description,
                              icon: isSkill
                                  ? Icons.bolt_outlined
                                  : Icons.terminal,
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                _insertPrompt(_commandInsertion(command));
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
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
  final bool selected;
  final bool isModelPicker;
  final IconData? icon;
  final VoidCallback onTap;

  const _ComposerAction({
    required this.label,
    this.selected = false,
    this.isModelPicker = false,
    this.icon,
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
  final VoidCallback onTap;

  const _ComposerChip({
    required this.label,
    this.icon,
    required this.selected,
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

    return Material(
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
