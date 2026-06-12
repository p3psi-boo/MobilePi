import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/node_provider.dart';
import '../utils/text.dart';
import 'project_sessions_screen.dart';

/// Node 详情页 —— 该 Node 上的 Project 列表（卡片式）。
class NodeProjectsScreen extends StatelessWidget {
  final String nodeId;

  const NodeProjectsScreen({super.key, required this.nodeId});

  static String _projectName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    if (trimmed.isEmpty) return path;
    return trimmed.split('/').last;
  }

  Future<void> _openProjectPicker(BuildContext context) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => RemoteFolderPicker(nodeId: nodeId),
    );
    if (selected == null || selected.isEmpty || !context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProjectSessionsScreen(
          nodeId: nodeId,
          projectId: '$nodeId::$selected',
          projectPath: selected,
          projectName: _projectName(selected),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Selector<NodeProvider, String>(
          selector: (ctx, p) => p.getNode(nodeId)?.hostname ?? 'Node',
          builder: (ctx, name, _) => Text(name),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openProjectPicker(context),
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        elevation: 0,
        icon: const Icon(Icons.create_new_folder_rounded),
        label: const Text(
          '添加项目',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      body: Selector<NodeProvider, List<ProjectState>>(
        selector: (ctx, p) => p.projectsForNode(nodeId),
        shouldRebuild: (a, b) => a.length != b.length || !_shallowEqual(a, b),
        builder: (ctx, projects, _) {
          if (projects.isEmpty) {
            return const _EmptyState(
              icon: Icons.folder_off_rounded,
              text: '该 Node 上还没有 Project',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: projects.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) {
              final project = projects[i];
              return _ProjectCard(
                project: project,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ProjectSessionsScreen(
                      nodeId: nodeId,
                      projectId: project.id,
                      projectPath: project.path,
                      projectName: project.name,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  static bool _shallowEqual(List<ProjectState> a, List<ProjectState> b) {
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].sessionCount != b[i].sessionCount ||
          a[i].lastSeenAt != b[i].lastSeenAt) {
        return false;
      }
    }
    return true;
  }
}

class _ProjectCard extends StatelessWidget {
  final ProjectState project;
  final VoidCallback onTap;
  const _ProjectCard({required this.project, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.folder_rounded, color: cs.primary, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      project.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.5),
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 12,
                          color: cs.onSurface.withValues(alpha: 0.45),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${project.sessionCount} 个 Session',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                        if (project.lastSeenAt != null) ...[
                          const SizedBox(width: 10),
                          Text(
                            relativeTime(project.lastSeenAt!),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.45),
                            ),
                          ),
                        ],
                      ],
                    ),
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
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyState({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: cs.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 10),
          Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── 远端文件夹选择器 ────────────────────────────

/// Bottom-sheet 远端目录选择器：
/// - 顶部显示当前路径 + 返回上级
/// - 中部列出子目录（点击进入）
/// - 底部：新建子文件夹 / 选择此文件夹
class RemoteFolderPicker extends StatefulWidget {
  final String nodeId;
  const RemoteFolderPicker({super.key, required this.nodeId});

  @override
  State<RemoteFolderPicker> createState() => _RemoteFolderPickerState();
}

class _RemoteFolderPickerState extends State<RemoteFolderPicker> {
  DirectoryListing? _listing;
  bool _loading = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  Future<void> _load(String? path) async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final listing = await context.read<NodeProvider>().browseDirectory(
        widget.nodeId,
        path: path,
      );
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '$e';
        _loading = false;
      });
    }
  }

  String? _parentOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    if (normalized.isEmpty || normalized == '/') return null;
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final idx = trimmed.lastIndexOf('/');
    if (idx <= 0) return '/';
    return trimmed.substring(0, idx);
  }

  Future<void> _createSubfolder() async {
    final listing = _listing;
    if (listing == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => const _NewFolderDialog(),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final provider = context.read<NodeProvider>();
    try {
      final newPath = await provider.createDirectory(
        widget.nodeId,
        parentPath: listing.path,
        name: name.trim(),
      );
      if (!mounted) return;
      // refresh listing to include new folder, then jump into it as the selection
      Navigator.of(context).pop(newPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('创建失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final listing = _listing;
    final parent = listing == null ? null : _parentOf(listing.path);

    return FractionallySizedBox(
      heightFactor: 0.78,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          children: [
            // Grabber
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header: 路径 + 返回
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '上级目录',
                    icon: const Icon(Icons.arrow_upward_rounded),
                    onPressed: (parent != null && !_loading)
                        ? () => _load(parent)
                        : null,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '选择项目文件夹',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          listing?.path ?? '加载中…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.6),
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: _loading ? null : () => _load(listing?.path),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 子目录列表
            Expanded(child: _buildBody(cs, theme, listing)),
            // 底部操作
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: (listing == null || _loading)
                            ? null
                            : _createSubfolder,
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('新建子文件夹'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: (listing == null || _loading)
                            ? null
                            : () => Navigator.of(context).pop(listing.path),
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('选择此文件夹'),
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

  Widget _buildBody(
    ColorScheme cs,
    ThemeData theme,
    DirectoryListing? listing,
  ) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            _loadError!,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.error),
          ),
        ),
      );
    }
    if (listing == null) return const SizedBox.shrink();
    if (listing.entries.isEmpty) {
      return Center(
        child: Text(
          listing.error ?? '该目录下没有子文件夹',
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.55)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: listing.entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 0),
      itemBuilder: (ctx, i) {
        final entry = listing.entries[i];
        return ListTile(
          dense: true,
          leading: Icon(Icons.folder_rounded, color: cs.primary, size: 22),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Icon(
            Icons.chevron_right_rounded,
            color: cs.onSurface.withValues(alpha: 0.35),
          ),
          onTap: () => _load(entry.path),
        );
      },
    );
  }
}

class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog();

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建子文件夹'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: '文件夹名称'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('创建'),
        ),
      ],
    );
  }
}
