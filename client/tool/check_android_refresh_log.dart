import 'dart:io';

const _defaultMinRefreshHz = 90.0;

void main(List<String> args) {
  final inputPath = args.isNotEmpty ? args[0] : '-';
  final minRefreshHz = args.length > 1
      ? double.tryParse(args[1]) ?? _defaultMinRefreshHz
      : _defaultMinRefreshHz;

  final lines = inputPath == '-'
      ? _readStdinLines()
      : File(inputPath).readAsLinesSync();

  final events = lines
      .where((line) => line.contains('MobilePiRefresh'))
      .map(_parseRefreshEvent)
      .nonNulls
      .toList(growable: false);

  if (events.isEmpty) {
    stderr.writeln('No MobilePiRefresh events found.');
    exitCode = 1;
    return;
  }

  for (final event in events) {
    stdout.writeln(event.describe());
  }

  final selected = events
      .where((event) => event.isSelectionEvidence)
      .toList(growable: false);
  if (selected.isEmpty) {
    stderr.writeln('No refresh selection evidence found.');
    exitCode = 1;
    return;
  }

  final incomplete = selected
      .where((event) => event.missingEvidenceFields.isNotEmpty)
      .toList(growable: false);
  if (incomplete.isNotEmpty) {
    stderr.writeln('Refresh selection evidence is incomplete:');
    for (final event in incomplete) {
      stderr.writeln(
        '  - ${event.name} missing '
        '${event.missingEvidenceFields.join(', ')}',
      );
    }
    exitCode = 1;
    return;
  }

  final bestRefresh = selected
      .map((event) => event.refreshRateHz)
      .whereType<double>()
      .fold<double>(0, (best, value) => value > best ? value : best);

  if (bestRefresh < minRefreshHz) {
    stderr.writeln(
      'Selected refresh rate ${bestRefresh.toStringAsFixed(2)} Hz is below '
      'the ${minRefreshHz.toStringAsFixed(2)} Hz threshold.',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'PASS selected refresh rate ${bestRefresh.toStringAsFixed(2)} Hz >= '
    '${minRefreshHz.toStringAsFixed(2)} Hz',
  );
}

List<String> _readStdinLines() {
  final lines = <String>[];
  String? line;
  while ((line = stdin.readLineSync(encoding: systemEncoding)) != null) {
    lines.add(line!);
  }
  return lines;
}

_RefreshEvent? _parseRefreshEvent(String line) {
  final fields = <String, String>{};
  for (final match in RegExp(r'([A-Za-z]+)=([^ ]+)').allMatches(line)) {
    fields[match.group(1)!] = match.group(2)!;
  }
  final name = fields['event'];
  if (name == null) return null;
  final refreshRate = double.tryParse(
    fields['selectedRefreshRate'] ?? fields['refreshRate'] ?? '',
  );
  return _RefreshEvent(
    name: name,
    refreshRateHz: refreshRate,
    modeId: fields['selectedModeId'] ?? fields['modeId'],
    width: fields['width'],
    height: fields['height'],
  );
}

class _RefreshEvent {
  const _RefreshEvent({
    required this.name,
    required this.refreshRateHz,
    required this.modeId,
    required this.width,
    required this.height,
  });

  final String name;
  final double? refreshRateHz;
  final String? modeId;
  final String? width;
  final String? height;

  bool get isSelectionEvidence =>
      name == 'refresh_mode_selected' ||
      name == 'refresh_mode_already_selected';

  List<String> get missingEvidenceFields {
    final missing = <String>[];
    if (modeId == null || modeId!.isEmpty) {
      missing.add('modeId');
    }
    if (refreshRateHz == null || refreshRateHz! <= 0) {
      missing.add('refreshRate');
    }
    if (_positiveInt(width) == null) {
      missing.add('width');
    }
    if (_positiveInt(height) == null) {
      missing.add('height');
    }
    return missing;
  }

  String describe() {
    final refresh = refreshRateHz == null
        ? 'unknown'
        : '${refreshRateHz!.toStringAsFixed(2)} Hz';
    final resolution = width == null || height == null
        ? 'unknown'
        : '${width}x$height';
    return '$name mode=${modeId ?? 'unknown'} refresh=$refresh resolution=$resolution';
  }
}

int? _positiveInt(String? value) {
  final parsed = int.tryParse(value ?? '');
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}
