import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../services/log_buffer.dart';

/// 日志页 —— 订阅 [LogBuffer]，倒序显示最近的日志记录。
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  Level _minLevel = Level.INFO;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('日志'),
        actions: [
          PopupMenuButton<Level>(
            tooltip: '日志级别过滤',
            icon: const Icon(Icons.filter_list_rounded),
            initialValue: _minLevel,
            onSelected: (lv) => setState(() => _minLevel = lv),
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: Level.FINE, child: Text('全部 (FINE+)')),
              PopupMenuItem(value: Level.INFO, child: Text('INFO+')),
              PopupMenuItem(value: Level.WARNING, child: Text('WARNING+')),
              PopupMenuItem(value: Level.SEVERE, child: Text('SEVERE+')),
            ],
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => LogBuffer.instance.clear(),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<LogRecord>>(
        valueListenable: LogBuffer.instance.records,
        builder: (ctx, all, _) {
          final records = all
              .where((r) => r.level >= _minLevel)
              .toList(growable: false);
          if (records.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.event_note_rounded,
                    size: 40,
                    color: cs.onSurface.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '暂无日志',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            );
          }
          // 倒序：最新在顶
          final reversed = records.reversed.toList(growable: false);
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: reversed.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: cs.outlineVariant.withValues(alpha: 0.35),
            ),
            itemBuilder: (ctx, i) => _LogTile(record: reversed[i]),
          );
        },
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  final LogRecord record;
  const _LogTile({required this.record});

  Color _levelColor(BuildContext ctx) {
    final cs = Theme.of(ctx).colorScheme;
    if (record.level >= Level.SEVERE) return cs.error;
    if (record.level >= Level.WARNING) return const Color(0xFFFBBF24);
    if (record.level >= Level.INFO) return const Color(0xFF4ADE80);
    return cs.onSurface.withValues(alpha: 0.5);
  }

  String _timeStr() {
    final t = record.time;
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final color = _levelColor(context);

    final detail = StringBuffer()..write(record.message);
    if (record.error != null) {
      detail.write('\nerror: ${record.error}');
    }
    if (record.stackTrace != null) {
      detail.write('\n${record.stackTrace}');
    }
    final fullText = detail.toString();

    return InkWell(
      onLongPress: () async {
        await Clipboard.setData(ClipboardData(text: fullText));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已复制日志条目'),
            duration: Duration(seconds: 1),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 56,
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Text(
                record.level.name,
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  color: color,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        _timeStr(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontFamily: 'monospace',
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          record.loggerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.primary.withValues(alpha: 0.75),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    fullText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: cs.onSurface.withValues(alpha: 0.8),
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
