import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/node_provider.dart';
import '../utils/text.dart';
import 'task_create_screen.dart';
import 'task_detail_screen.dart';

/// Project 详情页 —— 历史 Session 列表 + 新建会话。
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
            child: Selector<NodeProvider, List<ProjectSessionState>>(
              selector: (ctx, p) => p.sessionsForProject(nodeId, projectId),
              shouldRebuild: (a, b) =>
                  a.length != b.length || !_shallowEqual(a, b),
              builder: (ctx, sessions, _) {
                if (sessions.isEmpty) {
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
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                  itemCount: sessions.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    return _SessionCard(session: sessions[i]);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static bool _shallowEqual(
    List<ProjectSessionState> a,
    List<ProjectSessionState> b,
  ) {
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].status != b[i].status ||
          a[i].title != b[i].title ||
          a[i].updatedAt != b[i].updatedAt) {
        return false;
      }
    }
    return true;
  }
}

class _SessionCard extends StatelessWidget {
  final ProjectSessionState session;
  const _SessionCard({required this.session});

  static String _statusLabel(String status) => switch (status) {
    'running' => '运行中',
    'waitingDecision' => '待确认',
    'completed' => '完成',
    'error' => '错误',
    'history' => '历史',
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final statusColor = switch (session.status) {
      'running' => const Color(0xFF4ADE80),
      'waitingDecision' => const Color(0xFFFBBF24),
      'error' => cs.error,
      _ => cs.onSurface.withValues(alpha: 0.4),
    };
    final label = _statusLabel(session.status);

    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          if (session.task != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => TaskDetailScreen(taskId: session.task!.id),
              ),
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.secondary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.chat_bubble_rounded,
                  size: 18,
                  color: cs.secondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stripTags(session.title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (label.isNotEmpty) ...[
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            label,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: statusColor,
                              fontWeight: FontWeight.w600,
                              fontSize: 11,
                            ),
                          ),
                        ],
                        if (session.updatedAt != null) ...[
                          if (label.isNotEmpty) const SizedBox(width: 10),
                          Text(
                            relativeTime(session.updatedAt!),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.5),
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
