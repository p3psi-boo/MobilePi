import 'dart:io';

const _requiredAreas = [
  'P-1',
  'P-2',
  'P-3',
  'P-4',
  'P-5',
  'P-6',
  'U-1',
  'U-2',
  'U-3',
  'D-1',
  'D-2',
  'D-3',
  'D-4',
  'D-5',
  'D-6',
  'Network',
];

const _defaultAuditPath =
    '../.trellis/workspace/bubu/mobilepi-refactor-audit.md';

void main(List<String> args) {
  final strictComplete = args.contains('--complete');
  final positionalArgs = args
      .where((arg) => arg != '--complete')
      .toList(growable: false);
  final auditPath = positionalArgs.isEmpty
      ? _defaultAuditPath
      : positionalArgs.first;
  final file = File(auditPath);
  if (!file.existsSync()) {
    stderr.writeln('Audit file not found: $auditPath');
    exitCode = 1;
    return;
  }

  final content = file.readAsStringSync();
  final rows = _parseEvidenceRows(content);
  final failures = <String>[];

  for (final area in _requiredAreas) {
    if (!rows.containsKey(area)) {
      failures.add('missing evidence matrix row for $area');
    }
  }

  final unknownAreas = rows.keys
      .where((area) => !_requiredAreas.contains(area))
      .toList(growable: false);
  if (unknownAreas.isNotEmpty) {
    failures.add('unknown evidence matrix area(s): ${unknownAreas.join(', ')}');
  }

  final invalidStatuses = rows.entries
      .where((entry) => !_isKnownStatus(entry.value.status))
      .map((entry) => '${entry.key}: ${entry.value.status}')
      .toList(growable: false);
  if (invalidStatuses.isNotEmpty) {
    failures.add('unknown status value(s): ${invalidStatuses.join(', ')}');
  }

  final partialAreas = rows.entries
      .where((entry) => entry.value.status.startsWith('Partial'))
      .map((entry) => entry.key)
      .toList(growable: false);
  if (partialAreas.isNotEmpty && !_hasRemainingGaps(content)) {
    failures.add(
      'partial area(s) require Remaining Completion Gaps: '
      '${partialAreas.join(', ')}',
    );
  }
  failures.addAll(_missingPartialGapMentions(content, partialAreas));
  failures.addAll(_missingDeviceEvidenceContracts(content, partialAreas));
  if (strictComplete && partialAreas.isNotEmpty) {
    failures.add(
      'completion requires no partial areas; still partial: '
      '${partialAreas.join(', ')}',
    );
  }
  if (strictComplete && _hasRemainingGaps(content)) {
    failures.add('completion requires Remaining Completion Gaps to be empty');
  }
  if (strictComplete) {
    failures.addAll(
      _missingDeviceEvidenceContracts(content, const ['P-6', 'U-3', 'Network']),
    );
  }

  if (failures.isNotEmpty) {
    stderr.writeln('Refactor audit check failed:');
    for (final failure in failures) {
      stderr.writeln('  - $failure');
    }
    exitCode = 1;
    return;
  }

  final provenCount = rows.values
      .where((row) => row.status.startsWith('Proven'))
      .length;
  final mode = strictComplete ? 'completion audit' : 'refactor audit';
  stdout.writeln(
    'PASS $mode covers ${rows.length} areas '
    '($provenCount proven, ${partialAreas.length} partial).',
  );
}

Map<String, _EvidenceRow> _parseEvidenceRows(String content) {
  final rows = <String, _EvidenceRow>{};
  var inMatrix = false;

  for (final line in content.split('\n')) {
    if (line.trim() == '## Current Evidence Matrix') {
      inMatrix = true;
      continue;
    }
    if (inMatrix && line.startsWith('## ')) break;
    if (!inMatrix || !line.trimLeft().startsWith('|')) continue;
    if (line.contains('---') || line.contains('Area | Requirement')) continue;

    final cells = line
        .split('|')
        .map((cell) => cell.trim())
        .where((cell) => cell.isNotEmpty)
        .toList(growable: false);
    if (cells.length < 4) continue;

    rows[cells[0]] = _EvidenceRow(
      requirement: cells[1],
      evidence: cells[2],
      status: cells[3],
    );
  }

  return rows;
}

bool _isKnownStatus(String status) {
  return status.startsWith('Proven') || status.startsWith('Partial');
}

bool _hasRemainingGaps(String content) {
  return _remainingGapSection(
    content,
  ).split('\n').any((line) => line.trimLeft().startsWith('- '));
}

String _remainingGapSection(String content) {
  final headerIndex = content.indexOf('## Remaining Completion Gaps');
  if (headerIndex < 0) return '';
  final afterHeader = content.substring(headerIndex);
  final nextHeaderIndex = afterHeader.indexOf('\n## ', 1);
  return nextHeaderIndex < 0
      ? afterHeader
      : afterHeader.substring(0, nextHeaderIndex);
}

List<String> _missingPartialGapMentions(
  String content,
  List<String> partialAreas,
) {
  if (partialAreas.isEmpty) return const [];

  final section = _remainingGapSection(content);
  final failures = <String>[];
  for (final area in partialAreas) {
    if (!section.contains(area)) {
      failures.add('Remaining Completion Gaps must mention partial area $area');
    }
  }
  return failures;
}

List<String> _missingDeviceEvidenceContracts(
  String content,
  List<String> partialAreas,
) {
  final contracts = <String, List<String>>{
    'P-6': [
      'android-device-check <device>',
      'client-device-acceptance <device> 8.3 90',
      'android-refresh-verify <device> 90',
      'client/build/android-refresh.log',
      'build/mobilepi-device-acceptance.json',
      'streaming_detail_timeline.timeline_summary.json',
      'dashboard_scroll_timeline.timeline_summary.json',
      'session_cache_hydration_timeline.timeline_summary.json',
      'app-profile.apk',
      'mobilepi-performance-drive.log',
      'tool/check_android_device.dart',
      'tool/check_android_refresh_log.dart',
      'tool/check_flutter_drive_log.dart',
      'tool/check_device_acceptance_manifest.dart',
    ],
    'U-3': [
      'client-interaction-test <device>',
      'integration_test/mobilepi_interaction_test.dart',
      'mobilepi-interaction-drive.log',
      'tool/check_flutter_drive_log.dart',
    ],
    'Network': [
      'android-lifecycle-verify <device>',
      'client/build/android-lifecycle.log',
      'tool/check_android_lifecycle_log.dart',
    ],
  };

  final failures = <String>[];
  for (final area in partialAreas) {
    final requiredMarkers = contracts[area];
    if (requiredMarkers == null) continue;
    for (final marker in requiredMarkers) {
      if (!content.contains(marker)) {
        failures.add('$area device evidence requires marker: $marker');
      }
    }
  }

  if (partialAreas.isNotEmpty &&
      !content.contains('client-device-artifacts-check')) {
    failures.add(
      'partial device evidence requires client-device-artifacts-check command',
    );
  }
  return failures;
}

class _EvidenceRow {
  const _EvidenceRow({
    required this.requirement,
    required this.evidence,
    required this.status,
  });

  final String requirement;
  final String evidence;
  final String status;
}
