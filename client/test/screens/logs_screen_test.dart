import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mobilepi_client/screens/logs_screen.dart';
import 'package:mobilepi_client/services/log_buffer.dart';

void main() {
  tearDown(() {
    LogBuffer.instance.clear();
  });

  testWidgets(
    'shows latest visible log record first without changing filters',
    (tester) async {
      LogBuffer.instance
        ..addForTesting(LogRecord(Level.INFO, 'oldest visible', 'test.log'))
        ..addForTesting(LogRecord(Level.FINE, 'hidden fine', 'test.log'))
        ..addForTesting(LogRecord(Level.WARNING, 'newest visible', 'test.log'));

      await tester.pumpWidget(const MaterialApp(home: LogsScreen()));

      expect(find.textContaining('hidden fine'), findsNothing);

      final newestTop = tester.getTopLeft(
        find.textContaining('newest visible'),
      );
      final oldestTop = tester.getTopLeft(
        find.textContaining('oldest visible'),
      );
      expect(newestTop.dy, lessThan(oldestTop.dy));
    },
  );
}
