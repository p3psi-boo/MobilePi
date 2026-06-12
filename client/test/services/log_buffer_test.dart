import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mobilepi_client/services/log_buffer.dart';

void main() {
  tearDown(() {
    LogBuffer.instance.clear();
  });

  test('keeps only the latest records up to capacity', () {
    for (var i = 0; i < LogBuffer.capacity + 25; i++) {
      LogBuffer.instance.addForTesting(
        LogRecord(Level.INFO, 'message $i', 'test.log'),
      );
    }

    final records = LogBuffer.instance.records.value;

    expect(records, hasLength(LogBuffer.capacity));
    expect(records.first.message, 'message 25');
    expect(records.last.message, 'message ${LogBuffer.capacity + 24}');
  });
}
