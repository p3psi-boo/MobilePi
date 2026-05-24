# 降低 Markdown 渲染对比度

## 背景
项目已迁移至 `gpt_markdown` 包渲染 AI 消息内容。默认主题中链接色（`Colors.blue`）、悬停色（`Colors.red`）和代码高亮色对比度过高，在深色/浅色模式下都较为刺眼。

## 目标
全局降低 Markdown 渲染的对比度，使阅读体验更柔和。

## 改动范围

### 1. app.dart — 注册 `GptMarkdownThemeData` 主题扩展
为 `ThemeData` 添加 `extensions`，覆盖以下属性以降低对比度：
- `linkColor`: 使用当前 `ColorScheme.primary` 并降低 alpha（~0.85），替代高饱和 `Colors.blue`
- `linkHoverColor`: 使用 `ColorScheme.secondary` 并降低 alpha（~0.9），替代 `Colors.red`
- `hrLineColor`: 使用 `ColorScheme.outlineVariant`，替代默认 `outline`
- `highlightColor`: 使用 `surfaceContainerHighest.withAlpha(50)`，降低行内高亮背景对比度

对 light / dark 主题分别注册。

### 2. task_detail_screen.dart — 降低直接样式中的对比度
- `buildMessageParts` 中的正文 `GptMarkdown`：`onSurface.withValues(alpha: 0.9)` → `0.85`
- `_ThinkingBlock` 中的思考文本：`onSurfaceVariant.withValues(alpha: 0.8)` → `0.75`

### 3. task_detail_screen.dart — 优化 Slash Command UI 间距
- `_ComposerChip`: `height: 42` → `32`, `padding: horizontal 14` → `12`, `borderRadius: 14` → `10`
- `_InputBar`: `separatorBuilder` 的 `SizedBox(width: 10)` → `6`, `ListView` 的 `height: 42` → `32`
- `_InputBar`: 内部 `SizedBox(height: 10)` → `6`

## 验收标准
- [ ] 浅色模式下 Markdown 链接颜色柔和，不再使用刺眼的纯蓝
- [ ] 深色模式下链接、分隔线、高亮背景同样保持低对比度
- [ ] 聊天消息正文和 Thinking 块文字透明度适度降低
- [ ] Slash Command 区域布局更加紧凑，间距减小
- [ ] 项目 lint / build 通过
