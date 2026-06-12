import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/node_state.dart';
import '../providers/node_provider.dart';
import 'task_detail_screen.dart';

/// 新对话页 —— Claude Mobile 风格 + 与「旧会话（详情页）」输入区一致：
/// - 中央 Hero 标题 + 建议气泡
/// - 输入框上方一条 chip 横向滚动条（模型 / 命令）
/// - 圆角输入框，内部含 添加图片 + 发送 按钮
/// - 仅按钮重建（ValueListenableBuilder），避免每次按键 rebuild 整页
class TaskCreateScreen extends StatefulWidget {
  final String? projectId;
  final String? projectPath;

  const TaskCreateScreen({super.key, this.projectId, this.projectPath});

  @override
  State<TaskCreateScreen> createState() => _TaskCreateScreenState();
}

class _TaskCreateScreenState extends State<TaskCreateScreen> {
  late final String? _projectId = widget.projectId;
  late final String? _projectPath = widget.projectPath;
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _sending = ValueNotifier<bool>(false);
  final _selectedModel = ValueNotifier<String?>(null); // null = 使用 node 默认模型

  static const _suggestions = <_Suggestion>[
    _Suggestion(icon: Icons.bug_report_rounded, label: '帮我修一个 bug'),
    _Suggestion(icon: Icons.science_rounded, label: '为这段代码补单测'),
    _Suggestion(icon: Icons.auto_awesome_rounded, label: '重构这个文件让它更清晰'),
    _Suggestion(icon: Icons.menu_book_rounded, label: '解释一下这段实现'),
  ];

  @override
  void dispose() {
    _sending.dispose();
    _selectedModel.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _useSuggestion(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    _focusNode.requestFocus();
  }

  void _insertPrompt(String insertion) {
    if (insertion.isEmpty) {
      _focusNode.requestFocus();
      return;
    }
    final value = _controller.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final nextText = text.replaceRange(start, end, insertion);
    final cursor = start + insertion.length;
    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: cursor),
    );
    _focusNode.requestFocus();
  }

  void _send() {
    final prompt = _controller.text.trim();
    if (prompt.isEmpty) return;

    final provider = context.read<NodeProvider>();
    final node = _defaultNode(provider.nodes);
    if (node == null) return;

    final project = _projectId != null
        ? ProjectState(
            id: _projectId,
            nodeId: node.nodeId,
            path: _projectPath ?? _projectId,
            name: _projectName(_projectPath ?? _projectId),
          )
        : provider.defaultProjectForNode(node.nodeId);
    final model = _selectedModel.value ?? _effectiveModel(node);
    final instanceId = _effectiveInstanceId(node);

    _sending.value = true;
    HapticFeedback.lightImpact();
    final taskId = provider.sendTaskCommand(
      prompt,
      nodeId: node.nodeId,
      projectId: project.id,
      projectPath: project.path,
      piInstanceId: instanceId,
      model: model,
    );

    _controller.clear();
    // 发完即进入会话（替换当前页，返回时回到首页）。
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: taskId)),
    );
  }

  NodeState? _defaultNode(List<NodeState> nodes) {
    final onlineNodes = nodes.where((n) => n.online).toList();
    if (onlineNodes.isEmpty) return null;
    return onlineNodes.first;
  }

  String? _effectiveModel(NodeState node) {
    if (node.piDefaultModel != null && node.piDefaultModel!.isNotEmpty) {
      return node.piDefaultModel;
    }
    if (node.piModels.isNotEmpty) return node.piModels.first.id;
    return null;
  }

  static String _projectName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    if (trimmed.isEmpty) return path;
    return trimmed.split('/').last;
  }

  String? _effectiveInstanceId(NodeState node) {
    for (final instance in node.piInstances) {
      if (instance.isDefault) return instance.id;
    }
    if (node.piInstances.isNotEmpty) return node.piInstances.first.id;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasOnlineNodes = context.select<NodeProvider, bool>(
      (p) => p.hasOnlineNodes,
    );

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('新对话'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!hasOnlineNodes) const _NoNodeWarning(),
            ValueListenableBuilder<bool>(
              valueListenable: _sending,
              builder: (context, sending, _) {
                if (!sending) return const SizedBox.shrink();
                return LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: cs.surface,
                );
              },
            ),
            Expanded(
              child: _TaskCreateHero(
                hasOnlineNodes: hasOnlineNodes,
                projectPath: _projectPath,
                suggestions: _suggestions,
                onSuggestionTap: _useSuggestion,
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _sending,
              builder: (context, sending, _) {
                return ValueListenableBuilder<String?>(
                  valueListenable: _selectedModel,
                  builder: (context, selectedModel, _) {
                    return _ComposerWrapper(
                      controller: _controller,
                      focusNode: _focusNode,
                      enabled: hasOnlineNodes && !sending,
                      selectedModel: selectedModel,
                      onModelChanged: (m) => _selectedModel.value = m,
                      onInsertPrompt: _insertPrompt,
                      onSend: _send,
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskCreateHero extends StatelessWidget {
  final bool hasOnlineNodes;
  final String? projectPath;
  final List<_Suggestion> suggestions;
  final ValueChanged<String> onSuggestionTap;

  const _TaskCreateHero({
    required this.hasOnlineNodes,
    required this.projectPath,
    required this.suggestions,
    required this.onSuggestionTap,
  });

  static String _projectName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    if (trimmed.isEmpty) return path;
    return trimmed.split('/').last;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 32, 22, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hasOnlineNodes ? '说点什么？' : '等待 Node 上线',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hasOnlineNodes
                ? 'Pi Agent 会在远端帮你执行任务'
                : '请先在 Hub / Node 端启动 Pi Agent',
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          if (projectPath != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_open_rounded, size: 13, color: cs.primary),
                  const SizedBox(width: 5),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      _projectName(projectPath!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 32),
          Text(
            '建议',
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 0.4,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final suggestion in suggestions)
                _SuggestionChip(
                  icon: suggestion.icon,
                  label: suggestion.label,
                  onTap: () => onSuggestionTap(suggestion.label),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Suggestion {
  final IconData icon;
  final String label;
  const _Suggestion({required this.icon, required this.label});
}

class _SuggestionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SuggestionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoNodeWarning extends StatelessWidget {
  const _NoNodeWarning();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '没有在线 Node，暂时无法开始对话',
              style: TextStyle(
                color: cs.onErrorContainer,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 拿到当前默认 online node 的模型 / 命令，渲染与 task_detail 一致的输入区
class _ComposerWrapper extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final String? selectedModel;
  final ValueChanged<String?> onModelChanged;
  final ValueChanged<String> onInsertPrompt;
  final VoidCallback onSend;

  const _ComposerWrapper({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.selectedModel,
    required this.onModelChanged,
    required this.onInsertPrompt,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<NodeProvider, NodeState?>(
      selector: (ctx, p) {
        for (final n in p.nodes) {
          if (n.online) return n;
        }
        return null;
      },
      builder: (ctx, node, _) {
        return _Composer(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          node: node,
          selectedModel: selectedModel ?? node?.piDefaultModel,
          onModelChanged: onModelChanged,
          onInsertPrompt: onInsertPrompt,
          onSend: onSend,
        );
      },
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final NodeState? node;
  final String? selectedModel;
  final ValueChanged<String?> onModelChanged;
  final ValueChanged<String> onInsertPrompt;
  final VoidCallback onSend;

  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.node,
    required this.selectedModel,
    required this.onModelChanged,
    required this.onInsertPrompt,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final models = node?.piModels ?? const <PiModelInfo>[];
    final commands = node?.piSlashCommands ?? const <PiSlashCommandInfo>[];

    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        MediaQuery.of(context).viewInsets.bottom > 0 ? 10 : 16,
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
          // ─── 顶部 chip 横向条 ───
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _ModelPickerChip(
                  models: models,
                  selectedModel: selectedModel,
                  onModelChanged: onModelChanged,
                ),
                const SizedBox(width: 6),
                _ComposerChip(
                  label: '命令',
                  icon: Icons.terminal_rounded,
                  onTap: () => _showCommandSheet(context, commands),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // ─── 圆角输入框（图片 + 文本 + 发送）───
          Container(
            constraints: const BoxConstraints(minHeight: 62),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.6),
                width: 0.8,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const SizedBox(width: 14),
                IconButton(
                  tooltip: '图片上传（即将支持）',
                  icon: const Icon(Icons.photo_camera_outlined),
                  color: cs.onSurface.withValues(alpha: 0.45),
                  onPressed: enabled
                      ? () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('图片上传即将支持'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        }
                      : null,
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: true,
                    enabled: enabled,
                    minLines: 1,
                    maxLines: 6,
                    textInputAction: TextInputAction.newline,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.4,
                      color: cs.onSurface,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      hintText: '发送消息…',
                      hintStyle: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.4),
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (ctx, value, _) {
                      final canSend = enabled && value.text.trim().isNotEmpty;
                      return _SendButton(enabled: canSend, onTap: onSend);
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '内容由AI生成',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.35),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  String _commandTitle(PiSlashCommandInfo c) {
    final prefix = c.source.toLowerCase() == 'skill' ? 'SKILL ' : '/';
    return '$prefix${c.name}';
  }

  String _commandInsertion(PiSlashCommandInfo c) =>
      c.source.toLowerCase() == 'skill'
      ? '<skill>${c.name}</skill> '
      : '/${c.name} ';

  void _showCommandSheet(
    BuildContext context,
    List<PiSlashCommandInfo> commands,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return _CommandSheet(
          commands: commands,
          commandTitle: _commandTitle,
          commandInsertion: _commandInsertion,
          onInsertPrompt: onInsertPrompt,
        );
      },
    );
  }
}

/// 命令选择面板（带搜索过滤）。
class _CommandSheet extends StatefulWidget {
  final List<PiSlashCommandInfo> commands;
  final String Function(PiSlashCommandInfo) commandTitle;
  final String Function(PiSlashCommandInfo) commandInsertion;
  final ValueChanged<String> onInsertPrompt;

  const _CommandSheet({
    required this.commands,
    required this.commandTitle,
    required this.commandInsertion,
    required this.onInsertPrompt,
  });

  @override
  State<_CommandSheet> createState() => _CommandSheetState();
}

class _CommandSheetState extends State<_CommandSheet> {
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
                  Icon(Icons.terminal_rounded, size: 18, color: cs.primary),
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
                  autofocus: false,
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
                        _CommandTile(
                          title: '/',
                          description: '插入 slash command 前缀',
                          icon: Icons.terminal_rounded,
                          onTap: () {
                            Navigator.of(context).pop();
                            widget.onInsertPrompt('/');
                          },
                        ),
                        _CommandTile(
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
                      itemBuilder: (ctx, i) {
                        final c = filtered[i];
                        final isSkill = c.source.toLowerCase() == 'skill';
                        final desc = c.description.trim().isEmpty
                            ? (isSkill ? '插入 skill 命令' : '插入 slash command')
                            : c.description;
                        return _CommandTile(
                          title: widget.commandTitle(c),
                          description: desc,
                          icon: isSkill
                              ? Icons.bolt_outlined
                              : Icons.terminal_rounded,
                          onTap: () {
                            Navigator.of(context).pop();
                            widget.onInsertPrompt(widget.commandInsertion(c));
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

class _ComposerChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  const _ComposerChip({required this.label, this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final foreground = cs.onSurface.withValues(alpha: 0.8);
    final background = cs.surfaceContainerLow;

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.6),
              width: 0.8,
            ),
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
                style: theme.textTheme.labelMedium?.copyWith(
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
    return last.length > 16 ? '${last.substring(0, 15)}…' : last;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasSelection = selectedModel != null && selectedModel!.isNotEmpty;
    final label = hasSelection ? _shortLabel(selectedModel!) : '模型';
    final foreground = hasSelection
        ? cs.primary
        : cs.onSurface.withValues(alpha: 0.8);
    final background = hasSelection
        ? cs.primary.withValues(alpha: 0.12)
        : cs.surfaceContainerLow;

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
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
                        Icons.restart_alt_rounded,
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
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: hasSelection
                  ? cs.primary.withValues(alpha: 0.45)
                  : cs.outlineVariant.withValues(alpha: 0.6),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tune_rounded, size: 14, color: foreground),
              const SizedBox(width: 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.expand_less_rounded,
                size: 14,
                color: foreground.withValues(alpha: 0.65),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommandTile extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final VoidCallback onTap;

  const _CommandTile({
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

class _SendButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  const _SendButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: '发送',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: enabled ? cs.primary : cs.onSurface.withValues(alpha: 0.08),
          shape: BoxShape.circle,
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? onTap : null,
            child: Center(
              child: Icon(
                Icons.arrow_upward_rounded,
                size: 20,
                color: enabled
                    ? cs.onPrimary
                    : cs.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
