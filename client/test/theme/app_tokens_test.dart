import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilepi_client/theme/app_tokens.dart';

void main() {
  group('AppTokens', () {
    test('maps task statuses to semantic colors', () {
      const tokens = AppTokens.light;
      final cs = ColorScheme.fromSeed(seedColor: tokens.brandSeed);

      expect(tokens.statusForTask('running', cs), tokens.statusRunning);
      expect(tokens.statusForTask('waitingDecision', cs), tokens.statusWaiting);
      expect(tokens.statusForTask('error', cs), cs.error);
      expect(tokens.statusForTask('queued', cs), tokens.statusIdle);
    });

    test('is available from ThemeData extension', () {
      const tokens = AppTokens.dark;
      final theme = ThemeData(extensions: const [tokens]);

      expect(theme.appTokens, same(tokens));
    });
  });
}
