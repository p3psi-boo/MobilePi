/// 文本处理工具。
library;

/// 相对时间显示（中文短格式）。
String relativeTime(DateTime t) {
  final elapsed = DateTime.now().difference(t);
  if (elapsed.inMinutes < 1) return '刚刚';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}分钟前';
  if (elapsed.inDays < 1) return '${elapsed.inHours}小时前';
  if (elapsed.inDays < 30) return '${elapsed.inDays}天前';
  return '${t.month}/${t.day}';
}
