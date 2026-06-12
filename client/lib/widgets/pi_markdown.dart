import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Pi-tui 风格的 Markdown 渲染器。
///
/// 设计原则（对齐 `refs/pi-mono/packages/tui/src/components/markdown.ts` 的
/// `MarkdownTheme` 与 `coding-agent/.../theme/dark.json` / `light.json`）：
///
/// - **降低对比度**：正文文本不使用 `onSurface` 满色，而是 `~0.72` alpha；
///   不同 markdown 元素之间用「色相」区分（heading=暖色、code=accent），
///   而不是用「明度」拉对比。
/// - **内联 code** 用 accent 色 + 极淡背景。
/// - **代码块** 用左侧细 border + 弱化背景 + 等宽字体，无强对比框。
/// - **链接** 用降饱和的 primary。
/// - **HR/列表点** 用 `outlineVariant` 等极淡色，不抢视觉。
class PiMarkdown extends StatefulWidget {
  static const int _cacheCapacity = 96;
  static final _renderCache = <_PiMarkdownRenderKey, Widget>{};

  final String text;

  /// 正文样式 override。默认会基于 [Theme] 自动派生一个低对比度样式。
  final TextStyle? style;

  /// `true` 时使用更小的字号 / 行高，给嵌套在 thinking / tool_result 等
  /// 二级容器里的 markdown 用。
  final bool dense;

  /// `true` 时使用反色文本（用户气泡里白底紫色背景上的白字场景）。
  /// 此时所有内部颜色都会落到给定的 [style.color] 上，不再叠加 theme accent，
  /// 以保证文字可读性。
  final bool inverted;

  const PiMarkdown(
    this.text, {
    super.key,
    this.style,
    this.dense = false,
    this.inverted = false,
  });

  @override
  State<PiMarkdown> createState() => _PiMarkdownState();

  @visibleForTesting
  static int get debugCacheSize => _renderCache.length;

  @visibleForTesting
  static void debugClearCache() {
    _renderCache.clear();
  }

  static Widget _cachedRender(
    _PiMarkdownRenderKey key,
    Widget Function() build,
  ) {
    final cached = _renderCache.remove(key);
    if (cached != null) {
      _renderCache[key] = cached;
      return cached;
    }

    final rendered = build();
    _renderCache[key] = rendered;
    if (_renderCache.length > _cacheCapacity) {
      _renderCache.remove(_renderCache.keys.first);
    }
    return rendered;
  }
}

class _PiMarkdownState extends State<PiMarkdown> {
  _PiMarkdownRenderKey? _renderKey;
  Widget? _rendered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final key = _PiMarkdownRenderKey(
      text: widget.text,
      style: widget.style,
      dense: widget.dense,
      inverted: widget.inverted,
      brightness: theme.brightness,
      colorScheme: cs,
      textTheme: theme.textTheme,
    );

    if (_rendered != null && key == _renderKey) {
      return _rendered!;
    }

    _renderKey = key;
    _rendered = PiMarkdown._cachedRender(
      key,
      () => _buildRenderedMarkdown(theme, cs),
    );
    return _rendered!;
  }

  Widget _buildRenderedMarkdown(ThemeData theme, ColorScheme cs) {
    final isDark = theme.brightness == Brightness.dark;

    // 基础正文样式 — 低对比度，柔和行高
    final baseStyle =
        widget.style ??
        (widget.dense ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)
            ?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.72),
              height: widget.dense ? 1.5 : 1.6,
            );

    // 反色场景：所有元素都用同一个 base color 的不同 alpha 表达层级，
    // 不再叠加 theme accent，避免在彩色背景上字看不清。
    final baseColor = baseStyle?.color ?? cs.onSurface;

    // 内联 code 的 accent 色 — 对应 pi-tui 的 mdCode（accent/teal）
    final inlineCodeColor = widget.inverted
        ? baseColor
        : (isDark
              ? cs.tertiary.withValues(alpha: 0.95)
              : cs.tertiary.withValues(alpha: 0.85));

    // 内联 code 的极淡背景 — 对应 pi-tui 没有背景，但 Flutter 平台习惯加个浅底
    final inlineCodeBg = widget.inverted
        ? baseColor.withValues(alpha: 0.18)
        : cs.surfaceContainerHighest.withValues(alpha: isDark ? 0.6 : 0.5);

    // 代码块边框 + 背景 — 对应 mdCodeBlockBorder=mediumGray
    final codeBlockBorder = widget.inverted
        ? baseColor.withValues(alpha: 0.25)
        : cs.outlineVariant.withValues(alpha: 0.6);
    final codeBlockBg = widget.inverted
        ? baseColor.withValues(alpha: 0.10)
        : cs.surfaceContainerHighest.withValues(alpha: isDark ? 0.45 : 0.4);
    final fontSize = baseStyle?.fontSize ?? 14;
    final codeBlockStyle = (baseStyle ?? const TextStyle()).copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const [
        'Courier New',
        'PingFang SC',
        'Microsoft YaHei',
        'sans-serif',
      ],
      fontSize: fontSize * 0.92,
      color: widget.inverted ? baseColor : cs.onSurface.withValues(alpha: 0.78),
      height: 1.45,
    );
    final codeBlockLabelStyle = theme.textTheme.labelSmall?.copyWith(
      color: widget.inverted
          ? baseColor.withValues(alpha: 0.6)
          : cs.onSurfaceVariant.withValues(alpha: 0.55),
      fontFamily: 'monospace',
      fontFamilyFallback: const [
        'Courier New',
        'PingFang SC',
        'Microsoft YaHei',
        'sans-serif',
      ],
      fontSize: 10,
      letterSpacing: 0.4,
    );

    return SelectionArea(
      child: GptMarkdown(
        widget.text,
        style: baseStyle,
        followLinkColor: widget.inverted,
        highlightBuilder: (context, content, textStyle) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: inlineCodeBg,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              content,
              style: textStyle.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const [
                  'Courier New',
                  'PingFang SC',
                  'Microsoft YaHei',
                  'sans-serif',
                ],
                color: inlineCodeColor,
                fontSize: fontSize * 0.92,
                height: 1.3,
              ),
            ),
          );
        },
        codeBuilder: (context, name, code, closed) {
          return _CodeBlock(
            name: name,
            code: code,
            inverted: widget.inverted,
            backgroundColor: codeBlockBg,
            borderColor: codeBlockBorder,
            textStyle: codeBlockStyle,
            labelStyle: codeBlockLabelStyle,
          );
        },
      ),
    );
  }
}

class _PiMarkdownRenderKey {
  final String text;
  final TextStyle? style;
  final bool dense;
  final bool inverted;
  final Brightness brightness;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  const _PiMarkdownRenderKey({
    required this.text,
    required this.style,
    required this.dense,
    required this.inverted,
    required this.brightness,
    required this.colorScheme,
    required this.textTheme,
  });

  @override
  bool operator ==(Object other) {
    return other is _PiMarkdownRenderKey &&
        other.text == text &&
        other.style == style &&
        other.dense == dense &&
        other.inverted == inverted &&
        other.brightness == brightness &&
        other.colorScheme == colorScheme &&
        other.textTheme == textTheme;
  }

  @override
  int get hashCode => Object.hash(
    text,
    style,
    dense,
    inverted,
    brightness,
    colorScheme,
    textTheme,
  );
}

class _CodeBlock extends StatelessWidget {
  final String name;
  final String code;
  final bool inverted;
  final Color backgroundColor;
  final Color borderColor;
  final TextStyle textStyle;
  final TextStyle? labelStyle;

  const _CodeBlock({
    required this.name,
    required this.code,
    required this.inverted,
    required this.backgroundColor,
    required this.borderColor,
    required this.textStyle,
    required this.labelStyle,
  });

  @override
  Widget build(BuildContext context) {
    // 去掉末尾多余换行，避免代码块底部出现额外空白行
    final trimmed = _trimTrailingNewlines(code);
    // 终端风格宽度：80 列等宽，手机屏幕外可以左右滑动。
    // 这样 Agent 输出的 ASCII 图表不会因为换行而变形。
    final fontSize = textStyle.fontSize ?? 14;
    final terminalWidth = 80 * fontSize * 0.6;
    final labelColor = labelStyle?.color;

    final scrollableChild = Container(
      constraints: BoxConstraints(minWidth: terminalWidth),
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: borderColor, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (name.isNotEmpty || !inverted)
            Padding(
              padding: const EdgeInsets.only(
                left: 12,
                right: 8,
                top: 6,
                bottom: 2,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name.isNotEmpty ? name : 'code',
                      style: labelStyle,
                    ),
                  ),
                  if (!inverted)
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Clipboard.setData(ClipboardData(text: trimmed));
                        final messenger = ScaffoldMessenger.maybeOf(context);
                        messenger?.showSnackBar(
                          const SnackBar(
                            content: Text('已复制代码'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.copy_rounded,
                              size: 14,
                              color: labelColor,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '复制',
                              style: labelStyle?.copyWith(fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: IntrinsicWidth(
              child: SelectableText(trimmed, style: textStyle),
            ),
          ),
        ],
      ),
    );
    return _HScrollCode(child: scrollableChild);
  }
}

/// 横向可滚动的代码块容器，带滚动条以提示「右侧还有内容」。
class _HScrollCode extends StatefulWidget {
  final Widget child;
  const _HScrollCode({required this.child});

  @override
  State<_HScrollCode> createState() => _HScrollCodeState();
}

class _HScrollCodeState extends State<_HScrollCode> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        child: widget.child,
      ),
    );
  }
}

String _trimTrailingNewlines(String text) {
  var end = text.length;
  while (end > 0 && text.codeUnitAt(end - 1) == 10) {
    end--;
  }
  return end == text.length ? text : text.substring(0, end);
}
