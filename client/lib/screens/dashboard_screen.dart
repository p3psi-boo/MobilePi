import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/node_state.dart';
import '../providers/node_provider.dart';
import '../utils/text.dart';
import 'about_screen.dart';
import 'kanban_screen.dart';
import 'logs_screen.dart';
import 'node_projects_screen.dart';
import 'settings_screen.dart';
import 'task_create_screen.dart';
import 'task_detail_screen.dart';
import '../widgets/grill_me_setup_dialog.dart';

/// MobilePi 主页 —— Claude Mobile 风格：
/// - 大字号问候 Hero
/// - 横向滑动 Node 头像带
/// - 卡片式最近任务列表
/// - 底部主 CTA 按钮（仿 Claude 的 “New chat”）
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final provider = context.read<NodeProvider>();
      await provider.loadSettings();
      if (!mounted) return;
      provider.connect();
    });
  }

  Future<void> _onRefresh() async {
    context.read<NodeProvider>().refresh();
  }

  void _openCreateTask() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const TaskCreateScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      drawer: const _AppDrawer(),
      body: SafeArea(
        child: RefreshIndicator(
          color: cs.primary,
          onRefresh: _onRefresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: _TopBar(onRefresh: _onRefresh),
              ),
              const SliverToBoxAdapter(child: _GreetingHero()),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              const SliverToBoxAdapter(child: _NodeCarouselSection()),
              const SliverToBoxAdapter(child: SizedBox(height: 28)),
              const SliverToBoxAdapter(
                child: _SectionHeader(title: '最近会话', icon: Icons.history),
              ),
              const _RecentTasksSliverList(),
              const SliverToBoxAdapter(child: SizedBox(height: 120)),
            ],
          ),
        ),
      ),
      floatingActionButton: _NewChatFab(onTap: _openCreateTask),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}

// ─────────────────────────── 顶部条 + 问候 Hero ────────────────────────────

class _TopBar extends StatelessWidget {
  final VoidCallback onRefresh;
  const _TopBar({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.menu_rounded),
            tooltip: '菜单',
            onPressed: () => Scaffold.of(context).openDrawer(),
            color: cs.onSurface.withValues(alpha: 0.75),
          ),
          const SizedBox(width: 2),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: cs.primary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Text(
              'M',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'MobilePi',
            style: TextStyle(
              color: cs.onSurface,
              fontWeight: FontWeight.w700,
              fontSize: 17,
              letterSpacing: -0.2,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: onRefresh,
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── 左侧抽屉 ────────────────────────────

class _AppDrawer extends StatelessWidget {
  const _AppDrawer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hubUrl = context.select<NodeProvider, String>((p) => p.hubUrl);

    return Drawer(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'M',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'MobilePi',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                        Text(
                          hubUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.5),
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              color: cs.outlineVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 8),
            _DrawerItem(
              icon: Icons.view_kanban_rounded,
              label: 'Kanban',
              onTap: () => _push(context, const KanbanScreen()),
            ),
            _DrawerItem(
              icon: Icons.local_fire_department_rounded,
              label: 'Grill Me (需求确认)',
              onTap: () => _handleGrillMe(context),
            ),
            _DrawerItem(
              icon: Icons.tune_rounded,
              label: '设置',
              onTap: () => _push(context, const SettingsScreen()),
            ),
            _DrawerItem(
              icon: Icons.event_note_rounded,
              label: '日志',
              onTap: () => _push(context, const LogsScreen()),
            ),
            _DrawerItem(
              icon: Icons.info_outline_rounded,
              label: '关于',
              onTap: () => _push(context, const AboutScreen()),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Text(
                'v0.1.0',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.35),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).pop(); // 关闭 drawer
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _handleGrillMe(BuildContext context) {
    Navigator.of(context).pop(); // 关闭 drawer
    
    final provider = context.read<NodeProvider>();
    final onlineNodes = provider.nodes.where((n) => n.online).toList();
    if (onlineNodes.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('无法启动需求确认'),
          content: const Text('当前没有在线的 Node 节点。请先连接并启动远端 Node 设备以开始需求确认。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
      return;
    }
    
    final targetNode = onlineNodes.first;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => GrillMeSetupDialog(nodeId: targetNode.nodeId),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: cs.onSurface.withValues(alpha: 0.75),
                ),
                const SizedBox(width: 14),
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GreetingHero extends StatelessWidget {
  const _GreetingHero();

  String _greetingByHour() {
    final h = DateTime.now().hour;
    if (h < 5) return '深夜好';
    if (h < 11) return '早上好';
    if (h < 14) return '中午好';
    if (h < 18) return '下午好';
    if (h < 22) return '晚上好';
    return '夜深了';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 28, 22, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _greetingByHour(),
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.5,
              color: cs.onSurface.withValues(alpha: 0.55),
              height: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '今天想做点什么？',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
              color: cs.onSurface,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── Node 横向头像带 ────────────────────────────

class _NodeCarouselSection extends StatelessWidget {
  const _NodeCarouselSection();

  @override
  Widget build(BuildContext context) {
    return Selector<NodeProvider, (List<NodeState>, bool)>(
      selector: (ctx, p) => (p.nodes, p.isConnecting),
      shouldRebuild: (a, b) =>
          a.$2 != b.$2 ||
          a.$1.length != b.$1.length ||
          !_listEqualByOnline(a.$1, b.$1),
      builder: (ctx, data, _) {
        final (nodes, isConnecting) = data;
        return _NodeCarousel(nodes: nodes, isConnecting: isConnecting);
      },
    );
  }

  static bool _listEqualByOnline(List<NodeState> a, List<NodeState> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].nodeId != b[i].nodeId || a[i].online != b[i].online) {
        return false;
      }
    }
    return true;
  }
}

class _NodeCarousel extends StatelessWidget {
  final List<NodeState> nodes;
  final bool isConnecting;

  const _NodeCarousel({required this.nodes, required this.isConnecting});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Node', icon: Icons.hub_rounded),
        const SizedBox(height: 8),
        if (nodes.isEmpty && isConnecting)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: LinearProgressIndicator(minHeight: 2),
          )
        else if (nodes.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Text(
              '暂无已注册 Node，等待 Hub 上线…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          )
        else
          SizedBox(
            height: 96,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: nodes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder: (ctx, i) => _NodeAvatar(node: nodes[i]),
            ),
          ),
      ],
    );
  }
}

class _NodeAvatar extends StatelessWidget {
  final NodeState node;
  const _NodeAvatar({required this.node});

  IconData _icon() => switch (node.platform.toLowerCase()) {
    'macos' => Icons.apple,
    'linux' => Icons.terminal,
    'windows' => Icons.window,
    'android' => Icons.android,
    'ios' => Icons.phone_iphone,
    _ => Icons.computer,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final online = node.online;

    return SizedBox(
      width: 72,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => NodeProjectsScreen(nodeId: node.nodeId),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: online
                          ? cs.primary.withValues(alpha: 0.12)
                          : cs.surfaceContainerLow,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: online
                            ? cs.primary.withValues(alpha: 0.55)
                            : cs.outlineVariant.withValues(alpha: 0.5),
                        width: online ? 1.6 : 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      _icon(),
                      size: 22,
                      color: online
                          ? cs.primary
                          : cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                  if (online)
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: const Color(0xFF4ADE80),
                          shape: BoxShape.circle,
                          border: Border.all(color: cs.surface, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                node.hostname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: online ? FontWeight.w600 : FontWeight.w400,
                  color: online
                      ? cs.onSurface
                      : cs.onSurface.withValues(alpha: 0.55),
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── Recent Tasks ────────────────────────────

class _RecentTasksSliverList extends StatelessWidget {
  const _RecentTasksSliverList();

  @override
  Widget build(BuildContext context) {
    return Selector<NodeProvider, List<TaskState>>(
      selector: (ctx, p) => p.recentTasks,
      shouldRebuild: (a, b) =>
          a.length != b.length || !_taskListShallowEqual(a, b),
      builder: (ctx, tasks, _) {
        if (tasks.isEmpty) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: _EmptyState(
                icon: Icons.chat_bubble_outline_rounded,
                text: '还没有会话，点击下方按钮开始新对话',
              ),
            ),
          );
        }
        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          sliver: SliverList.separated(
            itemCount: tasks.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => _RecentTaskCard(task: tasks[i]),
          ),
        );
      },
    );
  }

  static bool _taskListShallowEqual(List<TaskState> a, List<TaskState> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final ta = a[i];
      final tb = b[i];
      if (ta.id != tb.id ||
          ta.status != tb.status ||
          ta.progressPercent != tb.progressPercent ||
          ta.title != tb.title) {
        return false;
      }
    }
    return true;
  }
}

class _RecentTaskCard extends StatelessWidget {
  final TaskState task;
  const _RecentTaskCard({required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final node = context.select<NodeProvider, NodeState?>(
      (p) => p.getNode(task.nodeId),
    );
    final nodeName =
        node?.hostname ?? (task.nodeId.length > 8
            ? task.nodeId.substring(0, 8)
            : task.nodeId);

    final statusColor = switch (task.status) {
      'running' => const Color(0xFF4ADE80),
      'waitingDecision' => const Color(0xFFFBBF24),
      'error' => cs.error,
      'completed' => cs.onSurface.withValues(alpha: 0.4),
      _ => cs.onSurface.withValues(alpha: 0.45),
    };
    final statusLabel = switch (task.status) {
      'running' => '运行中',
      'waitingDecision' => '等待决策',
      'completed' => '已完成',
      'error' => '出错',
      'history' => '历史',
      _ => '',
    };

    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TaskDetailScreen(taskId: task.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.chat_rounded,
                      size: 16,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      stripTags(task.title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ),
                  if (task.status == 'running')
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      icon: Icon(
                        Icons.stop_circle_rounded,
                        color: cs.error,
                        size: 22,
                      ),
                      tooltip: '紧急停止',
                      onPressed: () => _confirmPanic(context, task),
                    )
                  else
                    Text(
                      relativeTime(task.createdAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (statusLabel.isNotEmpty)
                    _StatusPill(color: statusColor, label: statusLabel),
                  _MetaPill(icon: Icons.computer_rounded, label: nodeName),
                  _MetaPill(
                    icon: Icons.folder_open_rounded,
                    label: _shortPath(task.projectPath),
                  ),
                  if (task.model != null && task.model!.isNotEmpty)
                    _MetaPill(
                      icon: Icons.memory_rounded,
                      label: _shortModel(task.model!),
                    ),
                ],
              ),
              if (task.progressPercent != null) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    minHeight: 4,
                    value: task.progressPercent! / 100,
                    backgroundColor: cs.onSurface.withValues(alpha: 0.08),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _shortPath(String path) {
    final norm = path.replaceAll('\\', '/');
    final parts = norm.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length <= 2) return norm;
    return '…/${parts[parts.length - 2]}/${parts.last}';
  }

  static String _shortModel(String model) {
    final last = model.split('/').last;
    return last.length > 18 ? '${last.substring(0, 17)}…' : last;
  }

  void _confirmPanic(BuildContext context, TaskState task) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认终止'),
        content: Text('确定要强制终止任务「${stripTags(task.title)}」吗？'),
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

// ─────────────────────────── 小组件 ────────────────────────────

class _StatusPill extends StatelessWidget {
  final Color color;
  final String label;
  const _StatusPill({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MetaPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.5),
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: cs.onSurface.withValues(alpha: 0.5)),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.65),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  const _SectionHeader({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 20, 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: cs.onSurface.withValues(alpha: 0.55)),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: cs.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ],
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32, color: cs.onSurface.withValues(alpha: 0.35)),
          const SizedBox(height: 8),
          Text(
            text,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.55),
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _NewChatFab extends StatelessWidget {
  final VoidCallback onTap;
  const _NewChatFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: cs.primary,
        borderRadius: BorderRadius.circular(32),
        elevation: 6,
        shadowColor: cs.primary.withValues(alpha: 0.35),
        child: InkWell(
          borderRadius: BorderRadius.circular(32),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.edit_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(
                  '新对话',
                  style: TextStyle(
                    color: cs.onPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    letterSpacing: -0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
