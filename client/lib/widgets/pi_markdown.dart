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
class PiMarkdown extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // 基础正文样式 — 低对比度，柔和行高
    final baseStyle =
        style ??
        (dense
                ? theme.textTheme.bodySmall
                : theme.textTheme.bodyMedium)
            ?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.72),
              height: dense ? 1.5 : 1.6,
            );

    // 反色场景：所有元素都用同一个 base color 的不同 alpha 表达层级，
    // 不再叠加 theme accent，避免在彩色背景上字看不清。
    final baseColor = baseStyle?.color ?? cs.onSurface;

    // 内联 code 的 accent 色 — 对应 pi-tui 的 mdCode（accent/teal）
    final inlineCodeColor = inverted
        ? baseColor
        : (isDark
            ? cs.tertiary.withValues(alpha: 0.95)
            : cs.tertiary.withValues(alpha: 0.85));

    // 内联 code 的极淡背景 — 对应 pi-tui 没有背景，但 Flutter 平台习惯加个浅底
    final inlineCodeBg = inverted
        ? Colors.white.withValues(alpha: 0.18)
        : cs.surfaceContainerHighest.withValues(alpha: isDark ? 0.6 : 0.5);

    // 代码块边框 + 背景 — 对应 mdCodeBlockBorder=mediumGray
    final codeBlockBorder = inverted
        ? Colors.white.withValues(alpha: 0.25)
        : cs.outlineVariant.withValues(alpha: 0.6);
    final codeBlockBg = inverted
        ? Colors.white.withValues(alpha: 0.10)
        : cs.surfaceContainerHighest.withValues(alpha: isDark ? 0.45 : 0.4);
    final codeBlockTextColor = inverted
        ? baseColor
        : cs.onSurface.withValues(alpha: 0.78);
    final codeBlockLangColor = inverted
        ? baseColor.withValues(alpha: 0.6)
        : cs.onSurfaceVariant.withValues(alpha: 0.55);

    final fontSize = baseStyle?.fontSize ?? 14;

    return GptMarkdown(
      text,
      style: baseStyle,
      followLinkColor: inverted,
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
              fontFamilyFallback: const ['Courier New', 'PingFang SC', 'Microsoft YaHei', 'sans-serif'],
              color: inlineCodeColor,
              fontSize: fontSize * 0.92,
              height: 1.3,
            ),
          ),
        );
      },
      codeBuilder: (context, name, code, closed) {
        // 去掉末尾多余换行，避免代码块底部出现额外空白行
        final trimmed = code.replaceAll(RegExp(r'\n+$'), '');
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: codeBlockBg,
            borderRadius: BorderRadius.circular(6),
            border: Border(
              left: BorderSide(color: codeBlockBorder, width: 2),
            ),
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
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: codeBlockLangColor,
                            fontFamily: 'monospace',
                            fontFamilyFallback: const ['Courier New', 'PingFang SC', 'Microsoft YaHei', 'sans-serif'],
                            fontSize: 10,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                      if (!inverted)
                        InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => Clipboard.setData(
                            ClipboardData(text: trimmed),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.copy,
                              size: 12,
                              color: codeBlockLangColor,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: SelectableText(
                  trimmed,
                  style: (baseStyle ?? const TextStyle()).copyWith(
                    fontFamily: 'monospace',
                    fontFamilyFallback: const ['Courier New', 'PingFang SC', 'Microsoft YaHei', 'sans-serif'],
                    fontSize: fontSize * 0.92,
                    color: codeBlockTextColor,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
