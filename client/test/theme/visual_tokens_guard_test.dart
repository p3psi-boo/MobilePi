import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('screens and widgets use theme tokens instead of hardcoded visuals', () {
    final root = Directory.current;
    final sourceDirs = [
      Directory('${root.path}/lib/screens'),
      Directory('${root.path}/lib/widgets'),
    ];
    final forbidden = <RegExp>[
      RegExp(r'Color\(0x[0-9A-Fa-f]+\)'),
      RegExp(r'Colors\.(?!transparent\b)[A-Za-z_]+'),
      RegExp(r'BoxShadow\s*\('),
      RegExp(r'blurRadius\s*:'),
      RegExp(r'shadowColor\s*:'),
      RegExp(r'elevation\s*:\s*[1-9]'),
      RegExp(r'withOpacity\s*\('),
    ];
    final violations = <String>[];

    for (final dir in sourceDirs) {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final text = entity.readAsStringSync();
        final relative = entity.path.substring(root.path.length + 1);
        for (final pattern in forbidden) {
          for (final match in pattern.allMatches(text)) {
            final line = '\n'.allMatches(text.substring(0, match.start)).length;
            violations.add('$relative:${line + 1}: ${match.group(0)}');
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Use ThemeData/AppTokens/ColorScheme for screen and widget visuals. '
          'Colors.transparent is the only allowed Colors.* escape hatch.',
    );
  });
}
