import 'dart:io';

void main(List<String> args) {
  final inputPath = args.isNotEmpty ? args[0] : '-';
  final lines = inputPath == '-'
      ? _readStdinLines()
      : File(inputPath).readAsLinesSync();

  final events = lines
      .where((line) => line.contains('MobilePiLifecycle'))
      .map(_parseLifecycleEvent)
      .nonNulls
      .toList(growable: false);

  if (events.isEmpty) {
    stderr.writeln('No MobilePiLifecycle events found.');
    exitCode = 1;
    return;
  }

  for (final event in events) {
    stdout.writeln(event.describe());
  }

  final pauseIndex = events.indexWhere((event) => event.name == 'app_paused');
  if (pauseIndex == -1) {
    stderr.writeln('No app_paused lifecycle event found.');
    exitCode = 1;
    return;
  }

  final forcedReconnectIndex = events.indexWhere(
    (event) => event.name == 'app_resumed' && event.action == 'force_reconnect',
    pauseIndex + 1,
  );
  if (forcedReconnectIndex == -1) {
    final skippedIndex = events.indexWhere(
      (event) =>
          event.name == 'app_resumed' &&
          event.action == 'skip_missing_tenant_key',
      pauseIndex + 1,
    );
    stderr.writeln(
      skippedIndex != -1
          ? 'App resumed, but reconnect was skipped because tenant key is missing.'
          : 'No app_resumed action=force_reconnect event was logged after app_paused.',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'PASS app pause/resume forced WebSocket reconnect '
    '(pause #$pauseIndex, reconnect #$forcedReconnectIndex)',
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

_LifecycleEvent? _parseLifecycleEvent(String line) {
  final fields = <String, String>{};
  for (final match in RegExp(r'([A-Za-z_]+)=([^ ]+)').allMatches(line)) {
    fields[match.group(1)!] = match.group(2)!;
  }
  final name = fields['event'];
  if (name == null) return null;
  return _LifecycleEvent(name: name, action: fields['action']);
}

class _LifecycleEvent {
  const _LifecycleEvent({required this.name, required this.action});

  final String name;
  final String? action;

  String describe() {
    return '$name action=${action ?? 'none'}';
  }
}
