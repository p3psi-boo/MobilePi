import 'package:flutter_driver/flutter_driver.dart' as driver;
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() {
  const timelineKeys = [
    'streaming_detail_timeline',
    'dashboard_scroll_timeline',
    'session_cache_hydration_timeline',
  ];

  return integrationDriver(
    responseDataCallback: (data) async {
      if (data == null) return;

      for (final key in timelineKeys) {
        final timelineJson = data[key];
        if (timelineJson is! Map<String, dynamic>) continue;

        final timeline = driver.Timeline.fromJson(timelineJson);
        final summary = driver.TimelineSummary.summarize(timeline);
        await summary.writeTimelineToFile(
          key,
          pretty: true,
          includeSummary: true,
        );
      }
    },
  );
}
