import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/node_state.dart';
import '../providers/node_provider.dart';
import '../screens/node_projects_screen.dart';
import '../screens/task_detail_screen.dart';

/// Grill Me (需求拷问) 初始化配置弹窗
class GrillMeSetupDialog extends StatefulWidget {
  final String nodeId;

  const GrillMeSetupDialog({super.key, required this.nodeId});

  @override
  State<GrillMeSetupDialog> createState() => _GrillMeSetupDialogState();
}

class _GrillMeSetupDialogState extends State<GrillMeSetupDialog> {
  final _ideaController = TextEditingController();
  final _focusNode = FocusNode();
  String? _selectedPath;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<NodeProvider>();
      final defaultProject = provider.defaultProjectForNode(widget.nodeId);
      setState(() {
        _selectedPath = defaultProject.path;
      });
    });
  }

  @override
  void dispose() {
    _ideaController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _selectFolder() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => RemoteFolderPicker(nodeId: widget.nodeId),
    );
    if (selected != null && selected.isNotEmpty) {
      setState(() {
        _selectedPath = selected;
      });
    }
  }

  String _projectName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    if (trimmed.isEmpty) return path;
    return trimmed.split('/').last;
  }

  String? _effectiveModel(NodeState node) {
    if (node.piDefaultModel != null && node.piDefaultModel!.isNotEmpty) {
      return node.piDefaultModel;
    }
    if (node.piModels.isNotEmpty) return node.piModels.first.id;
    return null;
  }

  String? _effectiveInstanceId(NodeState node) {
    for (final instance in node.piInstances) {
      if (instance.isDefault) return instance.id;
    }
    if (node.piInstances.isNotEmpty) return node.piInstances.first.id;
    return null;
  }

  void _submit() {
    final path = _selectedPath;
    if (path == null || path.trim().isEmpty) return;

    final provider = context.read<NodeProvider>();
    final node = provider.getNode(widget.nodeId);
    if (node == null) return;

    final idea = _ideaController.text.trim();
    final prompt = idea.isNotEmpty
        ? '<skill>grill-me</skill> Let\'s grill me on the requirements of my new project. Here is my brief idea: $idea'
        : '<skill>grill-me</skill> Let\'s start the grill-me requirements alignment process for this new project!';

    final model = _effectiveModel(node);
    final instanceId = _effectiveInstanceId(node);

    setState(() => _submitting = true);

    final taskId = provider.sendTaskCommand(
      prompt,
      nodeId: widget.nodeId,
      projectId: '${widget.nodeId}::$path',
      projectPath: path,
      piInstanceId: instanceId,
      model: model,
    );

    setState(() => _submitting = false);
    
    // 关闭配置弹窗
    Navigator.of(context).pop();

    // 瞬间直达聊天会话页面
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TaskDetailScreen(taskId: taskId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      backgroundColor: cs.surfaceContainerLow,
      elevation: 6,
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      actionsPadding: const EdgeInsets.fromLTRB(16, 16, 24, 24),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.local_fire_department_rounded,
              color: Colors.orange,
              size: 28,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Grill Me 需求对齐',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '在空项目上开启与 AI 的高强度提问，深度推敲您的设计与产品构想。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.6),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            
            // 目录选择卡片
            Text(
              '项目工作目录',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 8),
            Material(
              color: cs.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.5),
                  width: 0.8,
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _submitting ? null : _selectFolder,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.folder_rounded,
                        color: cs.primary,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selectedPath != null
                                  ? _projectName(_selectedPath!)
                                  : '选择目录',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (_selectedPath != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                _selectedPath!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSurface.withValues(alpha: 0.45),
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: cs.onSurface.withValues(alpha: 0.35),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            
            // 一句话愿景输入框
            Text(
              '项目一句话愿景 (做什么?)',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ideaController,
              focusNode: _focusNode,
              enabled: !_submitting,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: '例如：一个基于 Flutter 的番茄钟应用，支持漂亮的深色模式与动画...',
                hintStyle: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.35),
                  fontSize: 13.5,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.6),
                    width: 0.8,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.6),
                    width: 0.8,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: cs.primary,
                    width: 1.5,
                  ),
                ),
                filled: true,
                fillColor: cs.surface,
              ),
              style: const TextStyle(fontSize: 14.5),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(
            '取消',
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.6),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        FilledButton.icon(
          onPressed: _submitting || _selectedPath == null ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.orange,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : const Icon(Icons.local_fire_department_rounded, size: 18),
          label: const Text(
            '开始拷问',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
