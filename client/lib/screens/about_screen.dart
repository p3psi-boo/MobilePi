import 'package:flutter/material.dart';

/// 关于页 —— 静态信息卡。
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: cs.onPrimary.withValues(alpha: 0.22),
                      width: 1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'M',
                    style: TextStyle(
                      fontSize: 38,
                      color: cs.onPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'MobilePi',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'MobilePi 指挥官 · 移动端客户端',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'v0.1.0',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.45),
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _Section(
            title: '简介',
            child: Text(
              'MobilePi 是一个手机端 Coding Agent 调度看板：'
              '把多台机器上的 Pi Agent 汇总到 Hub，再通过 WebSocket 推送到客户端，'
              '让你在路上就能审视、纠偏、追加任务。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.8),
                height: 1.55,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const _Section(
            title: '架构',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Bullet('Hub：消息路由 / 状态聚合'),
                _Bullet('Node：每台机器上的常驻 Daemon，托管 Pi Agent'),
                _Bullet('Client：你正在使用的移动端看板'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: '协议',
            child: Text(
              '基于 mobilepi_shared 中定义的统一 JSON 消息协议，'
              '所有节点之间用同一组 MessageType 互通。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.8),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 8),
          DefaultTextStyle.merge(
            style: theme.textTheme.bodyMedium ?? const TextStyle(),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.8),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
