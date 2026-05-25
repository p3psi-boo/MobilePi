import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../models/node_state.dart';
import '../providers/node_provider.dart';
import '../utils/text.dart' as text_utils;
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

  /// 剥离 `&lt;skill&gt;`, `&lt;thinking&gt;`, `&lt;tool_result&gt;` 等结构化标签
  /// （走带缓存的全局工具）
  static String _stripTags(String text) => text_utils.stripTags(text);

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
        return (t?.title ?? '', t?.status == 'running', t);
      },
      builder: (ctx, data, _) {
        final (title, isRunning, task) = data;
        return AppBar(
          title: Text(
            _TaskDetailScreenState._stripTags(title),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
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

  @override
  void initState() {
    super.initState();
    final provider = context.read<NodeProvider>();
    final task = provider.getTask(widget.taskId);

    if (task != null) {
      _lastMessageCount = task.messages.length;
      _lastStreamingText = task.streamingText ?? '';
      _hasMore = task.nextBeforeIndex == null || task.nextBeforeIndex! > 0;

      if (task.messages.isEmpty &&
          task.sessionPath != null &&
          task.sessionPath!.isNotEmpty) {
        _isLoadingMore = true;
        _isPrepending = true;
        provider.requestSessionMessages(
          task.nodeId,
          task.id,
          task.sessionPath!,
          limit: 20,
        );
      }
    }

    _scrollController.addListener(_onScroll);
    provider.addListener(_onProviderChanged);
    _scrollToBottom(animate: false);
  }

  @override
  void dispose() {
    context.read<NodeProvider>().removeListener(_onProviderChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pixels = _scrollController.position.pixels;
    if (pixels <= 50) {
      final provider = context.read<NodeProvider>();
      final task = provider.getTask(widget.taskId);
      if (task != null &&
          _hasMore &&
          !_isLoadingMore &&
          task.sessionPath != null &&
          task.sessionPath!.isNotEmpty) {
        setState(() {
          _isLoadingMore = true;
          _isPrepending = true;
        });
        provider.requestSessionMessages(
          task.nodeId,
          task.id,
          task.sessionPath!,
          limit: 20,
          beforeIndex: task.nextBeforeIndex,
        );
      }
    }
  }

  void _onProviderChanged() {
    if (!mounted) return;
    final task = context.read<NodeProvider>().getTask(widget.taskId);
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

    if (shouldScroll) {
      _scrollToBottom();
    }
  }

  void _adjustScrollAfterPrepend() {
    if (!_scrollController.hasClients) return;
    final oldMaxScrollExtent = _scrollController.position.maxScrollExtent;
    final oldScrollOffset = _scrollController.offset;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final newMaxScrollExtent = _scrollController.position.maxScrollExtent;
      final difference = newMaxScrollExtent - oldMaxScrollExtent;
      if (difference > 0) {
        _scrollController.jumpTo(oldScrollOffset + difference);
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
      if (max - current > 150 && animate) {
        return;
      }

      // Use jumpTo to avoid animation overlap lag during fast streaming
      _scrollController.jumpTo(max);
    });
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
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
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: Selector<NodeProvider, (List<PiSessionMessageInfo>, String?)>(
            selector: (ctx, p) {
              final task = p.getTask(widget.taskId);
              // task-level fallback model（用于没有 per-message model 的情况）
              String? fallbackModel = task?.model;
              if (fallbackModel == null || fallbackModel.isEmpty) {
                final node = p.getNode(task?.nodeId ?? '');
                fallbackModel = node?.piDefaultModel;
              }
              return (task?.messages ?? const [], fallbackModel);
            },
            shouldRebuild: (prev, next) =>
                prev.$1.length != next.$1.length || prev.$2 != next.$2,
            builder: (context, data, _) {
              final (messages, fallbackModel) = data;
              if (messages.isEmpty) {
                return const SliverToBoxAdapter(child: SizedBox.shrink());
              }
              return SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final msg = messages[index];
                  final isUser = msg.role == 'user';
                  bool showHeader = false;
                  if (!isUser) {
                    if (index == 0) {
                      showHeader = true;
                    } else {
                      final prevMsg = messages[index - 1];
                      if (prevMsg.role == 'user') {
                        showHeader = true;
                      } else {
                        final currentModel = msg.model ?? fallbackModel;
                        final prevModel = prevMsg.model ?? fallbackModel;
                        if (currentModel != prevModel) {
                          showHeader = true;
                        }
                      }
                    }
                  }
                  return _MessageItem(
                    key: ValueKey('msg_$index'),
                    message: msg,
                    isUser: isUser,
                    isFinal: true,
                    modelName: msg.model ?? fallbackModel,
                    showHeader: showHeader,
                  );
                }, childCount: messages.length),
              );
            },
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
          sliver: Selector<NodeProvider, (String?, bool, List<StreamingToolEvent>, bool, String?)>(
            selector: (ctx, p) {
              final t = p.getTask(widget.taskId);
              return (
                t?.streamingText,
                t?.status == 'running',
                t?.toolEvents ?? const [],
                t?.isThinking ?? false,
                t?.statusLabel,
              );
            },
            builder: (context, data, _) {
              final streamingText = data.$1;
              final isRunning = data.$2;
              final toolEvents = data.$3;
              final isThinking = data.$4;
              final statusLabel = data.$5;
              final hasContent = streamingText != null && streamingText.isNotEmpty ||
                  toolEvents.isNotEmpty || statusLabel != null;
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
                          Text('暂无输出', style: TextStyle(color: Colors.grey)),
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
                      if (streamingText != null &&
                          streamingText.length > _maxRenderedStreamingChars)
                        _OutputTruncationNotice(
                          omittedChars:
                              streamingText.length - _maxRenderedStreamingChars,
                        ),
                      // Markdown text (pure — no structural tags)
                      if (streamingText != null && streamingText.isNotEmpty)
                        ..._buildStreamingTextWidgets(
                          context,
                          streamingText,
                          isThinking: isThinking,
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
    );
  }

}

/// Streaming text rendered as markdown.
/// No structural tags — pure text.
List<Widget> _buildStreamingTextWidgets(
  BuildContext context,
  String streamingText, {
  bool isThinking = false,
  bool isFinal = true,
}) {
  final theme = Theme.of(context);
  final text = streamingText.length <= _maxRenderedStreamingChars
      ? streamingText
      : streamingText.substring(streamingText.length - _maxRenderedStreamingChars);
  if (text.trim().isEmpty) return [];
  final widget = RepaintBoundary(
    child: PiMarkdown(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        height: 1.6,
        color: cs.onSurface.withValues(alpha: 0.85),
      ),
    ),
  );
  if (isThinking) {
    return [RepaintBoundary(child: _ThinkingBlock(text: text))];
  }
  return [widget];
}

/// Render structured tool events as chips.
Widget _buildStreamingToolChips(
  BuildContext context,
  List<StreamingToolEvent> toolEvents, {
  bool isFinal = true,
}) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final chips = <Widget>[];

  for (int i = 0; i < toolEvents.length; i++) {
    final ev = toolEvents[i];
    if (ev.isResult) {
      chips.add(
        _ToolChip(
          key: ValueKey('tr_$i'),
          toolName: ev.name,
          status: ev.isError ? '失败' : '成功',
          content: ev.resultText,
        ),
      );
    } else {
      // Check if there's a matching result later
      bool hasResult = false;
      for (int j = i + 1; j < toolEvents.length; j++) {
        if (toolEvents[j].isResult && toolEvents[j].name == ev.name) {
          hasResult = true;
          break;
        }
      }
      chips.add(
        _ToolChip(
          key: ValueKey('tc_$i'),
          toolName: ev.name,
          status: null,
          isLoading: !isFinal && !hasResult,
        ),
      );
    }
  }

  if (chips.isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: chips,
    ),
  );
}

/// Transient status label (compaction, retry, etc.).
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
          SizedBox(width: 8),
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

/// 消息片段类型
enum _MessagePartType {
  markdown,
  thinking,
  toolCall,
  toolResult,
  skill,
  spacer,
}

/// 消息片段数据（不含 Widget，可安全缓存）
class _MessagePart {
  final _MessagePartType type;
  final String? text;
  final String? name;
  final String? status;
  final double? space;

  const _MessagePart.markdown(this.text)
    : type = _MessagePartType.markdown,
      name = null,
      status = null,
      space = null;

  const _MessagePart.thinking(this.text)
    : type = _MessagePartType.thinking,
      name = null,
      status = null,
      space = null;

  const _MessagePart.toolCall(this.name)
    : type = _MessagePartType.toolCall,
      text = null,
      status = null,
      space = null;

  const _MessagePart.toolResult(this.name, this.status, this.text)
    : type = _MessagePartType.toolResult,
      space = null;

  const _MessagePart.skill(this.name)
    : type = _MessagePartType.skill,
      text = null,
      status = null,
      space = null;

  const _MessagePart.spacer(this.space)
    : type = _MessagePartType.spacer,
      text = null,
      name = null,
      status = null;
}

/// 解析器 — 正则编译一次，解析结果 LRU 缓存
class _MessagePartsParser {
  static final _thinkingRegex = RegExp(
    r'<thinking>(.*?)</thinking>',
    dotAll: true,
  );
  static final _toolRegex = RegExp(r'\[工具: (.+?)\]');
  static final _toolResultRegex = RegExp(
    r'<tool_result name="(.+?)" status="(.+?)">(.*?)</tool_result>',
    dotAll: true,
  );
  static final _skillRegex = RegExp(r'<skill>(.*?)</skill>', dotAll: true);
  static final _allMarkersRegex = RegExp(
    r'(<thinking>.*?</thinking>|\[工具: .+?\]|<tool_result .*?>.*?</tool_result>|<skill>.*?</skill>)',
    dotAll: true,
  );

  static final _cache = <String, List<_MessagePart>>{};
  static const _maxCacheSize = 100;

  static List<_MessagePart> parse(String text) {
    final normalizedText = text_utils.closeOpenThinkingTag(text);
    final cached = _cache[normalizedText];
    if (cached != null) return cached;

    final result = _doParse(normalizedText);

    if (_cache.length >= _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    _cache[normalizedText] = result;

    return result;
  }

  static List<_MessagePart> _doParse(String text) {
    final parts = <_MessagePart>[];
    int lastIndex = 0;
    var lastToolCallName = '';

    final matches = _allMarkersRegex.allMatches(text);
    for (final match in matches) {
      if (match.start > lastIndex) {
        _addMarkdown(parts, text.substring(lastIndex, match.start));
        lastToolCallName = '';
      }

      final matchText = match.group(0)!;
      if (matchText.startsWith('<thinking>')) {
        lastToolCallName = '';
        final thinking =
            _thinkingRegex.firstMatch(matchText)?.group(1)?.trim() ?? '';
        parts.add(_MessagePart.thinking(thinking));
      } else if (matchText.startsWith('[工具:')) {
        final toolName =
            _toolRegex.firstMatch(matchText)?.group(1) ?? 'unknown';
        if (toolName != lastToolCallName) {
          lastToolCallName = toolName;
          parts.add(_MessagePart.toolCall(toolName));
        }
      } else if (matchText.startsWith('<tool_result')) {
        lastToolCallName = '';
        final m = _toolResultRegex.firstMatch(matchText);
        final name = m?.group(1) ?? 'unknown';
        final status = m?.group(2) ?? '';
        final content = m?.group(3)?.trim() ?? '';
        parts.add(_MessagePart.toolResult(name, status, content));
      } else if (matchText.startsWith('<skill>')) {
        lastToolCallName = '';
        final skillName =
            _skillRegex.firstMatch(matchText)?.group(1)?.trim() ?? '';
        parts.add(_MessagePart.skill(skillName));
      }

      lastIndex = match.end;
    }

    if (lastIndex < text.length) {
      _addMarkdown(parts, text.substring(lastIndex));
    }

    return parts;
  }

  static void _addMarkdown(List<_MessagePart> parts, String raw) {
    final leading = _countNewlines(raw, leading: true);
    final trailing = _countNewlines(raw, leading: false);

    _addSpacing(parts, leading);

    final trimmed = raw.trim();
    if (trimmed.isNotEmpty) {
      parts.add(_MessagePart.markdown(trimmed));
    }

    _addSpacing(parts, trailing);
  }

  static int _countNewlines(String s, {bool leading = true}) {
    int count = 0;
    if (leading) {
      for (int i = 0; i < s.length && s[i] == '\n'; i++) {
        count++;
      }
    } else {
      for (int i = s.length - 1; i >= 0 && s[i] == '\n'; i--) {
        count++;
      }
    }
    return count;
  }

  static void _addSpacing(List<_MessagePart> parts, int count) {
    if (count >= 2) {
      parts.add(const _MessagePart.spacer(8));
    } else if (count >= 1) {
      parts.add(const _MessagePart.spacer(4));
    }
  }
}

/// 构建 Widgets — 基于缓存的解析结果，每次 build 只做 widget 创建
List<Widget> _buildMessagePartWidgets(
  BuildContext context,
  List<_MessagePart> parts, {
  bool isFinal = true,
}) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final widgets = <Widget>[];

  int i = 0;
  while (i < parts.length) {
    final part = parts[i];

    if (part.type == _MessagePartType.toolCall ||
        part.type == _MessagePartType.toolResult ||
        part.type == _MessagePartType.skill) {
      final toolWidgets = <Widget>[];
      int j = i;

      while (j < parts.length) {
        final nextPart = parts[j];
        if (nextPart.type == _MessagePartType.toolCall) {
          bool hasResult = false;
          for (int k = j + 1; k < parts.length; k++) {
            if (parts[k].type == _MessagePartType.toolResult &&
                parts[k].name == nextPart.name) {
              hasResult = true;
              break;
            }
          }
          if (!hasResult) {
            toolWidgets.add(
              _ToolChip(
                key: ValueKey('tc_$j'),
                toolName: nextPart.name!,
                status: null,
                isLoading: !isFinal,
              ),
            );
          }
        } else if (nextPart.type == _MessagePartType.toolResult) {
          toolWidgets.add(
            _ToolChip(
              key: ValueKey('tr_$j'),
              toolName: nextPart.name!,
              status: nextPart.status,
              content: nextPart.text,
            ),
          );
        } else if (nextPart.type == _MessagePartType.skill) {
          toolWidgets.add(
            _ToolChip(
              key: ValueKey('sk_$j'),
              toolName: nextPart.name!,
              status: 'skill',
            ),
          );
        } else if (nextPart.type == _MessagePartType.spacer) {
          // ignore spacer inside tool groups
        } else {
          // Break group if it's text, thinking, etc.
          // BUT ignore empty markdown
          if (nextPart.type == _MessagePartType.markdown &&
              (nextPart.text == null || nextPart.text!.trim().isEmpty)) {
            // ignore
          } else {
            break;
          }
        }
        j++;
      }

      if (toolWidgets.isNotEmpty) {
        widgets.add(
          Padding(
            key: ValueKey('tg_$i'),
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: toolWidgets,
            ),
          ),
        );
      }
      i = j;
      continue;
    }

    switch (part.type) {
      case _MessagePartType.markdown:
        widgets.add(
          RepaintBoundary(
            key: ValueKey('md_$i'),
            child: PiMarkdown(
              part.text!,
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.6,
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ),
        );
        break;
      case _MessagePartType.thinking:
        widgets.add(
          RepaintBoundary(
            key: ValueKey('think_$i'),
            child: _ThinkingBlock(text: part.text!),
          ),
        );
        break;
      case _MessagePartType.spacer:
        widgets.add(SizedBox(key: ValueKey('sp_$i'), height: part.space!));
        break;
      default:
        break;
    }
    i++;
  }

  return widgets;
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

      // toolResult 角色的消息（独立 JSONL 条目）直接静默渲染内容，不显示 header
      if (isToolResult) {
        final parsedParts = _MessagePartsParser.parse(message.text);
        return Padding(
          padding: const EdgeInsets.only(bottom: 4, left: 4, right: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: _buildMessagePartWidgets(
              context,
              parsedParts,
              isFinal: isFinal,
            ),
          ),
        );
      }

      final parsedParts = _MessagePartsParser.parse(message.text);

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
            ..._buildMessagePartWidgets(context, parsedParts, isFinal: isFinal),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!_expanded) {
      // Collapsed: minimal inline label, Pi-style
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
              Text(
                '思考...',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.5,
                  ),
                  fontStyle: FontStyle.italic,
                  height: 1.4,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isRunning = widget.isLoading;
    final isSkill = widget.status == 'skill';
    final isSuccess =
        widget.status == '成功' || widget.status == 'success' || isSkill;
    final hasContent = widget.content != null && widget.content!.isNotEmpty;
    final canExpand = !isRunning && !isSkill && hasContent;

    final icon = _getIconForTool(widget.toolName, widget.status);
    final dimColor = cs.onSurfaceVariant.withValues(alpha: 0.45);

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
                Text(
                  isRunning ? '正在使用 ${widget.toolName}...' : widget.toolName,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    color: isRunning
                        ? cs.primary.withValues(alpha: 0.5)
                        : dimColor,
                    fontWeight: FontWeight.w400,
                  ),
                ),
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

/// 状态呼吸灯
class _StatusDot extends StatelessWidget {
  final bool online;
  const _StatusDot({required this.online});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: online ? Colors.green : Colors.grey,
        boxShadow: online
            ? [
                BoxShadow(
                  color: Colors.green.withValues(alpha: 0.4),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
    );
  }
}
