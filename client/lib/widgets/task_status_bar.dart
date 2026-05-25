import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../models/node_state.dart';
import '../providers/node_provider.dart';

class TaskStatusBar extends StatefulWidget {
  final String taskId;
  const TaskStatusBar({super.key, required this.taskId});

  @override
  State<TaskStatusBar> createState() => _TaskStatusBarState();
}

class _TaskStatusBarState extends State<TaskStatusBar> {
  static const Duration _throttle = Duration(milliseconds: 220);
  DateTime? _lastSetAt;
  Timer? _timer;
  ({int input, int output, int cacheRead, double percent, int contextWindow})?
  _display;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static String _formatTokens(int count) {
    if (count < 1000) return count.toString();
    if (count < 10000) return '${(count / 1000).toStringAsFixed(1)}k';
    if (count < 1000000) return '${(count / 1000).round()}k';
    if (count < 10000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    return '${(count / 1000000).round()}M';
  }

  static int? _intVal(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

  static double? _doubleVal(Object? v) {
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '');
  }

  static Map<String, dynamic>? _mapVal(Object? v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  static ({int input, int output, int cacheRead, double percent, int contextWindow}) _buildStats(TaskState task, NodeState? node) {
    var totalInput = 0;
    var totalOutput = 0;
    var totalCacheRead = 0;

    for (final msg in task.messages) {
      if (msg.role != 'assistant') continue;
      final usage = msg.usage;
      if (usage == null) continue;
      totalInput += usage.input;
      totalOutput += usage.output;
      totalCacheRead += usage.cacheRead;
    }

    final piState = node?.piState;
    final contextUsage =
        _mapVal(piState?['contextUsage']) ?? _mapVal(piState?['context']);
    final percent =
        _doubleVal(contextUsage?['percent']) ??
        _doubleVal(piState?['contextPercent']) ??
        0;

    final modelId = task.model ?? node?.piDefaultModel;
    final model = node?.piModels.where((m) => m.id == modelId).firstOrNull;
    final contextWindow =
        _intVal(contextUsage?['contextWindow']) ??
        _intVal(piState?['contextWindow']) ??
        model?.contextWindow ??
        0;

    return (
      input: totalInput,
      output: totalOutput,
      cacheRead: totalCacheRead,
      percent: percent,
      contextWindow: contextWindow,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Selector<NodeProvider, (TaskState?, NodeState?)>(
      selector: (ctx, p) {
        final t = p.getTask(widget.taskId);
        NodeState? node;
        if (t != null) {
          for (final n in p.nodes) {
            if (n.nodeId == t.nodeId) {
              node = n;
              break;
            }
          }
        }
        return (t, node);
      },
      builder: (ctx, data, _) {
        final (task, node) = data;
        if (task == null) return const SizedBox.shrink();

        final theme = Theme.of(context);
        final next = _buildStats(task, node);
        final now = DateTime.now();
        final last = _lastSetAt;
        if (_display == null || last == null || now.difference(last) >= _throttle) {
          _display = next;
          _lastSetAt = now;
        } else {
          _timer?.cancel();
          _timer = Timer(_throttle - now.difference(last), () {
            if (!mounted) return;
            setState(() {
              _display = next;
              _lastSetAt = DateTime.now();
            });
          });
        }
        final stats = _display ?? next;
        final textStyle = theme.textTheme.bodySmall?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
          color: theme.colorScheme.onSurfaceVariant,
        );

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      Text('↑', style: textStyle),
                      _FlipStatNumber(
                        value: stats.input > 0 ? _formatTokens(stats.input) : '-',
                        style: textStyle,
                      ),
                      const SizedBox(width: 8),
                      Text('↓', style: textStyle),
                      _FlipStatNumber(
                        value: stats.output > 0 ? _formatTokens(stats.output) : '-',
                        style: textStyle,
                      ),
                      if (stats.cacheRead > 0) ...[
                        const SizedBox(width: 8),
                        Text('R${_formatTokens(stats.cacheRead)}', style: textStyle),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${stats.percent.toStringAsFixed(1)}%/${stats.contextWindow > 0 ? _formatTokens(stats.contextWindow) : '-'}',
                style: textStyle?.copyWith(
                  color: stats.percent > 90
                      ? theme.colorScheme.error
                      : (stats.percent > 70
                            ? theme.colorScheme.tertiary
                            : theme.colorScheme.onSurfaceVariant),
                ),
                textAlign: TextAlign.right,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FlipStatNumber extends StatelessWidget {
  final String value;
  final TextStyle? style;

  const _FlipStatNumber({required this.value, this.style});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final rotate = Tween<double>(
          begin: -math.pi / 2,
          end: 0,
        ).animate(animation);
        return AnimatedBuilder(
          animation: rotate,
          child: child,
          builder: (context, c) {
            final v = rotate.value;
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.002)
                ..rotateX(v),
              child: Opacity(opacity: animation.value.clamp(0, 1), child: c),
            );
          },
        );
      },
      child: Text(value, key: ValueKey<String>(value), style: style),
    );
  }
}
