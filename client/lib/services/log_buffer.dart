import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';

/// 一个进程级单例：把 `Logger.root` 的日志写到一个环形缓冲区，并通过
/// `ValueListenable` 暴露给 UI（日志页订阅它即可实时刷新）。
///
/// 同时还会在 debug 模式下把日志打到控制台（`debugPrint`），方便开发。
class LogBuffer {
  LogBuffer._();

  static final LogBuffer instance = LogBuffer._();

  static const int capacity = 500;

  final ValueNotifier<List<LogRecord>> records = ValueNotifier<List<LogRecord>>(
    <LogRecord>[],
  );

  bool _attached = false;

  /// 调用一次即可，将 `Logger.root` 接入。
  void attach() {
    if (_attached) return;
    _attached = true;

    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen(_onRecord);
  }

  void _onRecord(LogRecord record) {
    _append(record);

    if (kDebugMode) {
      debugPrint(formatLogRecord(record));
    }
  }

  void _append(LogRecord record) {
    final next = List<LogRecord>.from(records.value)..add(record);
    if (next.length > capacity) {
      next.removeRange(0, next.length - capacity);
    }
    records.value = next;
  }

  void clear() {
    records.value = const <LogRecord>[];
  }

  @visibleForTesting
  void addForTesting(LogRecord record) {
    _append(record);
  }
}
