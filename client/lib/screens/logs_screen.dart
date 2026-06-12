import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../services/log_buffer.dart';
import '../theme/app_tokens.dart';

/// 日志页 —— 订阅 [LogBuffer]，倒序显示最近的日志记录。
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  Level _minLevel = Level.INFO;

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('确定要清空所有本地日志吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      HapticFeedback.mediumImpact();
      LogBuffer.instance.clear();
    }
  }

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
            onPressed: _confirmClear,
          ),
        ],
      ),
      body: LogsPanel(minLevel: _minLevel),
    );
  }
}

class LogsPanel extends StatelessWidget {
  final Level minLevel;
  final ScrollController? scrollController;

  const LogsPanel({
    super.key,
    this.minLevel = Level.INFO,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return ValueListenableBuilder<List<LogRecord>>(
      valueListenable: LogBuffer.instance.records,
      builder: (ctx, all, _) {
        final visibleCount = _visibleLogCount(all, minLevel);
        if (visibleCount == 0) {
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
        return ListView.separated(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          itemCount: visibleCount,
          separatorBuilder: (_, _) => Divider(
            height: 1,
            color: cs.outlineVariant.withValues(alpha: 0.35),
          ),
          itemBuilder: (ctx, i) =>
              _LogTile(record: _visibleLogAtNewestFirst(all, minLevel, i)),
        );
      },
    );
  }
}

int _visibleLogCount(List<LogRecord> records, Level minLevel) {
  var count = 0;
  for (final record in records) {
    if (record.level >= minLevel) count++;
  }
  return count;
}

LogRecord _visibleLogAtNewestFirst(
  List<LogRecord> records,
  Level minLevel,
  int index,
) {
  var seen = 0;
  for (var i = records.length - 1; i >= 0; i--) {
    final record = records[i];
    if (record.level < minLevel) continue;
    if (seen == index) return record;
    seen++;
  }
  throw RangeError.index(index, records, 'index');
}

class _LogTile extends StatelessWidget {
  final LogRecord record;
  const _LogTile({required this.record});

  Color _levelColor(BuildContext ctx) {
    final cs = Theme.of(ctx).colorScheme;
    final tokens = Theme.of(ctx).appTokens;
    if (record.level >= Level.SEVERE) return cs.error;
    if (record.level >= Level.WARNING) return tokens.statusWaiting;
    if (record.level >= Level.INFO) return tokens.statusRunning;
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
        HapticFeedback.selectionClick();
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
            SizedBox(
              width: 64,
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      record.level.name,
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                        color: color,
                        letterSpacing: 0.5,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
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
