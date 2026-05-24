/// 文本处理工具（带 LRU 缓存）。
///
/// `stripTags` 用于剥离 Agent 输出里的 `<skill>` / `<thinking>` /
/// `<tool_result>` 等结构化标签，用作 UI 的纯文本预览（例如 AppBar 标题、
/// 会话列表条目、Dashboard 最近任务等）。
///
/// 同一段长文本会在每次 build 时被反复调用，因此带上一个小容量缓存避免
/// 重复跑正则。
library;

const int _kMaxCacheSize = 128;

final RegExp _skillRegex = RegExp(r'<skill>.*?</skill>', dotAll: true);
final RegExp _thinkingRegex = RegExp(r'<thinking>.*?</thinking>', dotAll: true);
final RegExp _toolResultRegex = RegExp(
  r'<tool_result .*?>.*?</tool_result>',
  dotAll: true,
);
final RegExp _openThinkingRegex = RegExp(r'<thinking>.*$', dotAll: true);

final Map<String, String> _stripCache = <String, String>{};

/// If a streaming assistant update has started a thinking block but has not
/// emitted the closing marker yet, append the marker for display parsing.
String closeOpenThinkingTag(String text) {
  if (text.isEmpty) return text;
  final lastOpen = text.lastIndexOf('<thinking>');
  if (lastOpen < 0) return text;

  final lastClose = text.lastIndexOf('</thinking>');
  if (lastClose > lastOpen) return text;

  return '$text\n</thinking>';
}

/// 剥离结构化标签，返回干净的纯文本。
String stripTags(String text) {
  if (text.isEmpty) return text;
  final cached = _stripCache[text];
  if (cached != null) return cached;

  final result = text
      .replaceAll(_skillRegex, '')
      .replaceAll(_thinkingRegex, '')
      .replaceAll(_openThinkingRegex, '')
      .replaceAll(_toolResultRegex, '')
      .trim();

  if (_stripCache.length >= _kMaxCacheSize) {
    _stripCache.remove(_stripCache.keys.first);
  }
  _stripCache[text] = result;
  return result;
}

/// 相对时间显示（中文短格式）。
String relativeTime(DateTime t) {
  final elapsed = DateTime.now().difference(t);
  if (elapsed.inMinutes < 1) return '刚刚';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}分钟前';
  if (elapsed.inDays < 1) return '${elapsed.inHours}小时前';
  if (elapsed.inDays < 30) return '${elapsed.inDays}天前';
  return '${t.month}/${t.day}';
}
