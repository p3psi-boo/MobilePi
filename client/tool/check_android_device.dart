import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty || args.first.trim().isEmpty) {
    stderr.writeln('Usage: dart run tool/check_android_device.dart <device>');
    exitCode = 64;
    return;
  }

  final expectedDevice = args.first.trim();
  final lines = args.length > 1
      ? File(args[1]).readAsLinesSync()
      : _runAdbDevices();
  final devices = _parseAdbDevices(lines);
  final state = devices[expectedDevice];

  if (state == 'device') {
    stdout.writeln('PASS Android device $expectedDevice is connected.');
    return;
  }

  if (state == null) {
    final connected = devices.isEmpty
        ? 'none'
        : devices.entries
              .map((entry) => '${entry.key}(${entry.value})')
              .join(', ');
    stderr.writeln(
      'Android device $expectedDevice was not found. Connected devices: '
      '$connected.',
    );
    exitCode = 1;
    return;
  }

  stderr.writeln(
    'Android device $expectedDevice is in state "$state"; expected "device".',
  );
  exitCode = 1;
}

List<String> _runAdbDevices() {
  final result = Process.runSync('adb', ['devices']);
  if (result.exitCode != 0) {
    stderr.writeln('adb devices failed: ${result.stderr}');
    exitCode = result.exitCode;
    return const <String>[];
  }
  return (result.stdout as String).split('\n');
}

Map<String, String> _parseAdbDevices(List<String> lines) {
  final devices = <String, String>{};
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('List of devices')) continue;
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    devices[parts[0]] = parts[1];
  }
  return devices;
}
