import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/check_flutter_drive_log.dart <log> [required-marker...]',
    );
    exitCode = 64;
    return;
  }

  final logFile = File(args.first);
  final requiredMarkers = args.skip(1).toList(growable: false);
  if (!logFile.existsSync()) {
    stderr.writeln('Flutter drive log not found: ${args.first}');
    exitCode = 1;
    return;
  }

  final content = logFile.readAsStringSync();
  final failures = [
    'Some tests failed.',
    'Test failed.',
    'DriverError',
    'Exception:',
    'Failed to load',
  ].where(content.contains).toList(growable: false);

  if (failures.isNotEmpty) {
    stderr.writeln(
      'Flutter drive log contains failure marker(s): ${failures.join(', ')}',
    );
    exitCode = 1;
    return;
  }

  final hasSuccessMarker =
      content.contains('All tests passed!') ||
      content.contains('All tests passed.');
  if (!hasSuccessMarker) {
    stderr.writeln(
      'Flutter drive log has no final success marker ("All tests passed").',
    );
    exitCode = 1;
    return;
  }

  final missingMarkers = requiredMarkers
      .where((marker) => !content.contains(marker))
      .toList(growable: false);
  if (missingMarkers.isNotEmpty) {
    stderr.writeln(
      'Flutter drive log is missing required marker(s): '
      '${missingMarkers.join(', ')}',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln('PASS Flutter drive log ${args.first} reports success.');
}
