import 'dart:convert';
import 'dart:io';

const _timelineKeys = [
  'streaming_detail_timeline',
  'dashboard_scroll_timeline',
  'session_cache_hydration_timeline',
];
const _manifestSchema = 3;

void main(List<String> args) {
  final writeMode = args.isNotEmpty && args.first == '--write';
  if (writeMode && args.length != 10 || !writeMode && args.length != 9) {
    stderr.writeln(
      'Usage: dart run tool/check_device_acceptance_manifest.dart '
      '[--write] <manifest> <device> <budget-ms> <min-hz> <build-dir> '
      '<refresh-log> <lifecycle-log> <performance-log> <interaction-log>',
    );
    exitCode = 64;
    return;
  }

  final offset = writeMode ? 1 : 0;
  final manifestPath = args[offset];
  final expected = _ExpectedRun(
    device: args[offset + 1],
    budgetMs: args[offset + 2],
    minHz: args[offset + 3],
    artifacts: {
      'buildDir': args[offset + 4],
      'refreshLog': args[offset + 5],
      'lifecycleLog': args[offset + 6],
      'performanceLog': args[offset + 7],
      'interactionLog': args[offset + 8],
    },
  );
  final expectedArtifacts = _expandedArtifacts(expected.artifacts);

  if (writeMode) {
    _writeManifest(manifestPath, expected, expectedArtifacts);
  } else {
    _checkManifest(manifestPath, expected, expectedArtifacts);
  }
}

void _writeManifest(
  String manifestPath,
  _ExpectedRun expected,
  Map<String, String> expectedArtifacts,
) {
  final artifactStats = <String, Map<String, Object>>{};
  final failures = <String>[];

  for (final entry in expectedArtifacts.entries) {
    final entity = _artifactEntity(entry.value);
    if (!entity.existsSync()) {
      failures.add('${entry.key} not found: ${entry.value}');
      continue;
    }
    final stat = entity.statSync();
    final artifact = <String, Object>{
      'path': entry.value,
      'type': _typeName(stat.type),
    };
    if (stat.type != FileSystemEntityType.directory) {
      artifact
        ..['bytes'] = stat.size
        ..['modifiedAt'] = stat.modified.toUtc().toIso8601String()
        ..['contentCrc32'] = _crc32Hex(File(entry.value).readAsBytesSync());
    }
    artifactStats[entry.key] = artifact;
  }

  if (failures.isNotEmpty) {
    stderr.writeln('Device acceptance manifest cannot be written:');
    for (final failure in failures) {
      stderr.writeln('  - $failure');
    }
    exitCode = 1;
    return;
  }

  final manifest = {
    'schema': _manifestSchema,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'device': expected.device,
    'budgetMs': expected.budgetMs,
    'minHz': expected.minHz,
    'artifacts': artifactStats,
  };
  final file = File(manifestPath)..parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
  stdout.writeln('PASS wrote device acceptance manifest $manifestPath.');
}

void _checkManifest(
  String manifestPath,
  _ExpectedRun expected,
  Map<String, String> expectedArtifacts,
) {
  final file = File(manifestPath);
  if (!file.existsSync()) {
    stderr.writeln('Device acceptance manifest not found: $manifestPath');
    exitCode = 1;
    return;
  }

  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    stderr.writeln('Device acceptance manifest is not a JSON object.');
    exitCode = 1;
    return;
  }

  final failures = <String>[];
  _expectEquals(failures, decoded['schema'], _manifestSchema, 'schema');
  _expectEquals(failures, decoded['device'], expected.device, 'device');
  _expectEquals(failures, decoded['budgetMs'], expected.budgetMs, 'budgetMs');
  _expectEquals(failures, decoded['minHz'], expected.minHz, 'minHz');

  final manifestArtifacts = decoded['artifacts'];
  if (manifestArtifacts is! Map<String, dynamic>) {
    failures.add('artifacts must be a JSON object');
  } else {
    for (final entry in expectedArtifacts.entries) {
      final actual = manifestArtifacts[entry.key];
      if (actual is! Map<String, dynamic>) {
        failures.add('artifact ${entry.key} is missing');
        continue;
      }
      _expectEquals(
        failures,
        actual['path'],
        entry.value,
        'artifact ${entry.key} path',
      );

      final entity = _artifactEntity(entry.value);
      if (!entity.existsSync()) {
        failures.add('artifact ${entry.key} not found: ${entry.value}');
        continue;
      }
      final stat = entity.statSync();
      _expectEquals(
        failures,
        actual['type'],
        _typeName(stat.type),
        'artifact ${entry.key} type',
      );
      if (stat.type != FileSystemEntityType.directory) {
        _expectEquals(
          failures,
          actual['bytes'],
          stat.size,
          'artifact ${entry.key} bytes',
        );
        _expectEquals(
          failures,
          actual['modifiedAt'],
          stat.modified.toUtc().toIso8601String(),
          'artifact ${entry.key} modifiedAt',
        );
        _expectEquals(
          failures,
          actual['contentCrc32'],
          _crc32Hex(File(entry.value).readAsBytesSync()),
          'artifact ${entry.key} contentCrc32',
        );
      }
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln('Device acceptance manifest check failed:');
    for (final failure in failures) {
      stderr.writeln('  - $failure');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln('PASS device acceptance manifest $manifestPath is current.');
}

Map<String, String> _expandedArtifacts(Map<String, String> baseArtifacts) {
  final artifacts = Map<String, String>.of(baseArtifacts);
  final buildDir = baseArtifacts['buildDir'];
  if (buildDir != null) {
    for (final key in _timelineKeys) {
      artifacts['${key}Summary'] = '$buildDir/$key.timeline_summary.json';
    }
    artifacts['profileApk'] =
        '$buildDir/app/outputs/flutter-apk/app-profile.apk';
  }
  return artifacts;
}

FileSystemEntity _artifactEntity(String path) {
  final type = FileSystemEntity.typeSync(path);
  return type == FileSystemEntityType.directory ? Directory(path) : File(path);
}

String _typeName(FileSystemEntityType type) {
  if (type == FileSystemEntityType.directory) return 'directory';
  if (type == FileSystemEntityType.file) return 'file';
  if (type == FileSystemEntityType.link) return 'link';
  return 'notFound';
}

String _crc32Hex(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i += 1) {
      final mask = -(crc & 1);
      crc = (crc >> 1) ^ (0xEDB88320 & mask);
    }
  }
  final value = (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  return value.toRadixString(16).padLeft(8, '0');
}

void _expectEquals(
  List<String> failures,
  Object? actual,
  Object? expected,
  String label,
) {
  if (actual != expected) {
    failures.add('$label expected "$expected" but found "$actual"');
  }
}

class _ExpectedRun {
  const _ExpectedRun({
    required this.device,
    required this.budgetMs,
    required this.minHz,
    required this.artifacts,
  });

  final String device;
  final String budgetMs;
  final String minHz;
  final Map<String, String> artifacts;
}
