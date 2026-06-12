import 'dart:convert';
import 'dart:io';

const _timelineKeys = [
  'streaming_detail_timeline',
  'dashboard_scroll_timeline',
  'session_cache_hydration_timeline',
];

const _defaultBudgetMs = 8.3;

const _requiredMetricKeys = [
  'average_frame_build_time',
  '90th_percentile_frame_build_time',
  '99th_percentile_frame_build_time',
  'average_frame_rasterizer_time',
  '90th_percentile_frame_rasterizer_time',
  '99th_percentile_frame_rasterizer_time',
];

void main(List<String> args) {
  final buildDir = args.isNotEmpty ? args[0] : 'build';
  final budgetMs = args.length > 1
      ? double.tryParse(args[1]) ?? _defaultBudgetMs
      : _defaultBudgetMs;

  final failures = <String>[];
  for (final key in _timelineKeys) {
    final file = _findSummaryFile(buildDir, key);
    if (file == null) {
      failures.add('$key: missing timeline summary under $buildDir');
      continue;
    }

    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      failures.add('$key: summary is not a JSON object (${file.path})');
      continue;
    }

    final metrics = _extractMetrics(decoded);
    final missingMetrics = _requiredMetricKeys
        .where((metricKey) => !metrics.containsKey(metricKey))
        .toList(growable: false);
    if (missingMetrics.isNotEmpty) {
      failures.add(
        '$key: missing frame timing metric(s) ${missingMetrics.join(', ')} '
        '(${file.path})',
      );
    }

    final sampleFailures = _validateSampleCounts(decoded);
    if (sampleFailures.isNotEmpty) {
      for (final failure in sampleFailures) {
        failures.add('$key: $failure (${file.path})');
      }
    }

    stdout.writeln('$key (${file.path})');
    for (final metric in metrics.entries) {
      final value = metric.value;
      final mark = value <= budgetMs ? 'PASS' : 'FAIL';
      stdout.writeln('  $mark ${metric.key}: ${value.toStringAsFixed(2)} ms');
      if (value > budgetMs) {
        failures.add(
          '$key ${metric.key} ${value.toStringAsFixed(2)} ms > '
          '${budgetMs.toStringAsFixed(2)} ms',
        );
      }
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln('Profile summary check failed:');
    for (final failure in failures) {
      stderr.writeln('  - $failure');
    }
    exitCode = 1;
  }
}

File? _findSummaryFile(String buildDir, String key) {
  final candidates = [
    '$buildDir/$key.timeline_summary.json',
    '$buildDir/${key}_summary.json',
    '$buildDir/$key.summary.json',
    '$buildDir/$key.json',
  ];
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) return file;
  }
  return null;
}

Map<String, double> _extractMetrics(Map<String, dynamic> json) {
  final result = <String, double>{};
  final source = json['summary'] is Map<String, dynamic>
      ? json['summary'] as Map<String, dynamic>
      : json;

  void collect(String label, List<String> keys) {
    for (final key in keys) {
      final value = _number(source[key]);
      if (value != null) {
        result[label] = _microsecondsToMilliseconds(value);
        return;
      }
    }
  }

  collect('average_frame_build_time', const [
    'average_frame_build_time_millis',
    'average_frame_build_time_millis.',
    'average_frame_build_time',
    'averageFrameBuildTimeMicros',
  ]);
  collect('90th_percentile_frame_build_time', const [
    '90th_percentile_frame_build_time_millis',
    '90th_percentile_frame_build_time',
    'percentile90FrameBuildTimeMicros',
  ]);
  collect('99th_percentile_frame_build_time', const [
    '99th_percentile_frame_build_time_millis',
    '99th_percentile_frame_build_time',
    'percentile99FrameBuildTimeMicros',
  ]);
  collect('average_frame_rasterizer_time', const [
    'average_frame_rasterizer_time_millis',
    'average_frame_rasterizer_time',
    'averageFrameRasterizerTimeMicros',
  ]);
  collect('90th_percentile_frame_rasterizer_time', const [
    '90th_percentile_frame_rasterizer_time_millis',
    '90th_percentile_frame_rasterizer_time',
    'percentile90FrameRasterizerTimeMicros',
  ]);
  collect('99th_percentile_frame_rasterizer_time', const [
    '99th_percentile_frame_rasterizer_time_millis',
    '99th_percentile_frame_rasterizer_time',
    'percentile99FrameRasterizerTimeMicros',
  ]);

  return result;
}

List<String> _validateSampleCounts(Map<String, dynamic> json) {
  final source = json['summary'] is Map<String, dynamic>
      ? json['summary'] as Map<String, dynamic>
      : json;
  final failures = <String>[];

  void requirePositive(String label, List<String> keys) {
    num? value;
    for (final key in keys) {
      value = _number(source[key]);
      if (value != null) break;
    }
    if (value == null) {
      failures.add('missing $label');
      return;
    }
    if (value <= 0) {
      failures.add('$label must be positive, got $value');
    }
  }

  requirePositive('frame_count', const ['frame_count', 'frameCount']);
  requirePositive('frame_rasterizer_count', const [
    'frame_rasterizer_count',
    'frameRasterizerCount',
  ]);

  return failures;
}

num? _number(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value);
  return null;
}

double _microsecondsToMilliseconds(num value) {
  final asDouble = value.toDouble();
  return asDouble > 1000 ? asDouble / 1000 : asDouble;
}
