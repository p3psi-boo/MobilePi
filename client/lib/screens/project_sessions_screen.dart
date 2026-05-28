import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/node_state.dart';
import '../providers/node_provider.dart';
import '../utils/text.dart';
import 'task_create_screen.dart';
import 'task_detail_screen.dart';

/// Project 详情页 —— 历史 Session 树 + 新建会话。
///
/// 按 Pi 的 fork 关系构建 session 父子树，
/// 用 ASCII 连接线 (`├──` / `└──` / `│`) 在手机上可视化分支结构。
class ProjectSessionsScreen extends StatelessWidget {
  final String nodeId;
  final String projectId;
  final String projectPath;
  final String projectName;

  const ProjectSessionsScreen({
    super.key,
    required this.nodeId,
    required this.projectId,
    required this.projectPath,
    required this.projectName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(projectName),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新 Session 列表',
            onPressed: () => context.read<NodeProvider>().refresh(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TaskCreateScreen(
              projectId: projectId,
              projectPath: projectPath,
            ),
          ),
        ),
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        elevation: 4,
        label: const Text('新会话',
            style: TextStyle(fontWeight: FontWeight.w600)),
        icon: const Icon(Icons.add_rounded),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              projectPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.5),
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(
            child: Selector<NodeProvider, NodeState?>(
              selector: (ctx, p) => p.getNode(nodeId),
              shouldRebuild: (a, b) =>
                  a?.piSessions.length != b?.piSessions.length ||
                  a?.piState?['sessionPath'] != b?.piState?['sessionPath'],
              builder: (ctx, node, _) {
                final allSessions = node?.piSessions ?? const [];
                // Filter to only sessions whose cwd matches this project path
                final projectSessions = allSessions
                    .where((s) => _isInProject(s.cwd, projectPath))
                    .toList();
                final activePath = node?.piState?['sessionPath']?.toString();
                if (projectSessions.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 40,
                          color: cs.onSurface.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '暂无 Session',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                final roots = _buildTree(projectSessions);
                return RefreshIndicator(
                  onRefresh: () async {
                    context.read<NodeProvider>().refresh();
                    await Future.delayed(const Duration(seconds: 1));
                  },
                  child: _SessionTreeView(
                    roots: roots,
                    activePath: activePath,
                    onSessionTap: (session) {
                      final taskId = 'pi-session:$nodeId:${session.id}';
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TaskDetailScreen(taskId: taskId),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Build a tree from flat sessions. Roots have no parent or parent not in list.
  static List<_SessionTreeNode> _buildTree(List<PiSessionInfo> sessions) {
    if (sessions.isEmpty) return [];

    // Sort all sessions by modified DESC so latest appears first at each level
    final sorted = List<PiSessionInfo>.from(sessions)
      ..sort((a, b) {
        final aTime = a.modified ?? a.created ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.modified ?? b.created ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });

    // Build lookup by path
    final byPath = <String, PiSessionInfo>{};
    for (final s in sorted) {
      if (s.path.isNotEmpty) byPath[s.path] = s;
    }

    // Group children by parent
    final childrenByParent = <String, List<PiSessionInfo>>{};
    for (final s in sorted) {
      final parent = s.parentSessionPath;
      if (parent != null && parent.isNotEmpty) {
        childrenByParent.putIfAbsent(parent, () => []).add(s);
      }
    }

    // Recursively build tree nodes
    List<_SessionTreeNode> buildNodes(List<PiSessionInfo> level,
        Set<String> seen, String? parentPath) {
      final nodes = <_SessionTreeNode>[];
      for (final s in level) {
        if (seen.contains(s.path)) continue;
        if (parentPath == null) {
          // Roots: no parent path, or parent not in our list
          if (s.parentSessionPath != null &&
              s.parentSessionPath!.isNotEmpty &&
              byPath.containsKey(s.parentSessionPath)) {
            continue; // Has a parent in list - not a root
          }
        } else {
          // Only include if this is a direct child of parentPath
          if (s.parentSessionPath != parentPath) continue;
        }
        seen.add(s.path);
        final childSessions = childrenByParent[s.path] ?? const [];
        nodes.add(_SessionTreeNode(
          session: s,
          children: buildNodes(childSessions, seen, s.path),
        ));
      }
      return nodes;
    }

    return buildNodes(sorted, <String>{}, null);
  }

  /// Returns true if [sessionCwd] belongs to [projectPath].
  /// Matches when cwd starts with projectPath (exact or trailing /).
  static bool _isInProject(String sessionCwd, String projectPath) {
    // Normalize paths to handle trailing slashes and different separators
    final cwd = sessionCwd.replaceAll('\\', '/');
    final proj = projectPath.replaceAll('\\', '/');
    if (cwd == proj) return true;
    if (cwd.startsWith('$proj/') || cwd.startsWith('$proj\\')) return true;
    // Also match if session cwd is empty (falls back to node default) and
    // projectPath is the "Current Project" default
    if (cwd.isEmpty && proj == 'Current Project') return true;
    return false;
  }
}

class _SessionTreeNode {
  final PiSessionInfo session;
  final List<_SessionTreeNode> children;
  _SessionTreeNode({required this.session, required this.children});
}

/// Stateful tree view that manages expand/collapse.
class _SessionTreeView extends StatefulWidget {
  final List<_SessionTreeNode> roots;
  final String? activePath;
  final ValueChanged<PiSessionInfo> onSessionTap;

  const _SessionTreeView({
    required this.roots,
    this.activePath,
    required this.onSessionTap,
  });

  @override
  State<_SessionTreeView> createState() => _SessionTreeViewState();
}

class _SessionTreeViewState extends State<_SessionTreeView> {
  final _expanded = <String>{};

  bool _isExpanded(String id) => _expanded.contains(id);

  void _toggle(String id) {
    setState(() {
      if (_expanded.contains(id)) {
        _expanded.remove(id);
      } else {
        _expanded.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    _buildList(items, widget.roots, 0, <bool>[]);
    if (items.isEmpty) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 96),
      children: items,
    );
  }

  /// Recursively flatten tree into widget list with tree connectors.
  void _buildList(
    List<Widget> out,
    List<_SessionTreeNode> nodes,
    int depth,
    List<bool> lastAtDepth, // true if ancestor at this depth was last sibling
  ) {
    for (int i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final isLast = i == nodes.length - 1;
      final hasChildren = node.children.isNotEmpty;
      final expanded = _isExpanded(node.session.id);

      out.add(
        _SessionTile(
          session: node.session,
          depth: depth,
          isLast: isLast,
          ancestorsLast: lastAtDepth,
          hasChildren: hasChildren,
          expanded: expanded,
          isActive: widget.activePath == node.session.path,
          onTap: () => widget.onSessionTap(node.session),
          onToggle: hasChildren ? () => _toggle(node.session.id) : null,
        ),
      );

      if (hasChildren && expanded) {
        _buildList(
          out,
          node.children,
          depth + 1,
          [...lastAtDepth, isLast],
        );
      }
    }
  }
}

/// A single session row with tree connectors, indent, and card.
class _SessionTile extends StatelessWidget {
  final PiSessionInfo session;
  final int depth;
  final bool isLast;
  final List<bool> ancestorsLast;
  final bool hasChildren;
  final bool expanded;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onToggle;

  const _SessionTile({
    required this.session,
    required this.depth,
    required this.isLast,
    required this.ancestorsLast,
    required this.hasChildren,
    required this.expanded,
    required this.isActive,
    required this.onTap,
    this.onToggle,
  });

  static const _kIndentPerLevel = 16.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dimColor = cs.onSurface.withValues(alpha: 0.35);

    final connector = isLast ? '└──' : '├──';
    final branchChar = '│';

    // Build indentation with vertical lines for ancestor branches
    final leading = <Widget>[];
    for (int d = 0; d < depth; d++) {
      final showLine = !ancestorsLast[d];
      leading.add(
        SizedBox(
          width: _kIndentPerLevel,
          child: showLine
              ? Text(
                  branchChar,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontFamilyFallback: const ['Courier New', 'PingFang SC', 'Microsoft YaHei', 'sans-serif'],
                    fontSize: 12,
                    color: dimColor,
                    height: 1.3,
                  ),
                )
              : null,
        ),
      );
    }
    // The connector for this tile
    leading.add(
      Text(
        connector,
        style: TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Courier New', 'PingFang SC', 'Microsoft YaHei', 'sans-serif'],
          fontSize: 12,
          color: dimColor,
          height: 1.3,
        ),
      ),
    );

    // Highlight style for active session
    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isActive
        ? cs.primaryContainer.withValues(alpha: isDark ? 0.35 : 0.45)
        : cs.surfaceContainerLow;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(
              children: [
                // Tree connectors
                if (depth > 0 || hasChildren)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: leading,
                  ),
                // Expand/collapse toggle for branches
                if (hasChildren)
                  GestureDetector(
                    onTap: onToggle,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        expanded
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_right_rounded,
                        size: 16,
                        color: dimColor,
                      ),
                    ),
                  ),
                const SizedBox(width: 6),
                // Active marker
                if (isActive)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      '✦',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.primary,
                        height: 1.0,
                      ),
                    ),
                  ),
                // Session icon (fork vs normal)
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: session.parentSessionPath != null &&
                            session.parentSessionPath!.isNotEmpty
                        ? cs.tertiary.withValues(alpha: 0.12)
                        : cs.secondary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    session.parentSessionPath != null &&
                            session.parentSessionPath!.isNotEmpty
                        ? Icons.call_split_rounded
                        : Icons.chat_bubble_rounded,
                    size: 14,
                    color: session.parentSessionPath != null &&
                            session.parentSessionPath!.isNotEmpty
                        ? cs.tertiary
                        : cs.secondary,
                  ),
                ),
                const SizedBox(width: 10),
                // Title + meta
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stripTags(session.displayTitle),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                          letterSpacing: -0.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            '${session.messageCount} msgs',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.45),
                              fontSize: 10,
                            ),
                          ),
                          if (session.updatedAt != null) ...[
                            const SizedBox(width: 8),
                            Text(
                              relativeTime(session.updatedAt!),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: cs.onSurface.withValues(alpha: 0.45),
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
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: cs.onSurface.withValues(alpha: 0.3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
