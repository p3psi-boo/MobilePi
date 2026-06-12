import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('check_profile_summaries.dart', () {
    test('passes when all timeline summaries stay within budget', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-profile-');
      addTearDown(() => dir.delete(recursive: true));

      for (final key in _timelineKeys) {
        _writeProfileSummary(dir, key, buildMs: 4.2, rasterMs: 5.1);
      }

      final result = await _runDartTool([
        'tool/check_profile_summaries.dart',
        dir.path,
        '8.3',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('streaming_detail_timeline'));
      expect(
        result.stdout,
        contains('PASS 99th_percentile_frame_rasterizer_time'),
      );
    });

    test('fails when any required profile metric exceeds budget', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-profile-');
      addTearDown(() => dir.delete(recursive: true));

      for (final key in _timelineKeys) {
        _writeProfileSummary(dir, key, buildMs: 4.2, rasterMs: 5.1);
      }
      _writeProfileSummary(
        dir,
        'dashboard_scroll_timeline',
        buildMs: 4.2,
        rasterMs: 10.4,
      );

      final result = await _runDartTool([
        'tool/check_profile_summaries.dart',
        dir.path,
        '8.3',
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('dashboard_scroll_timeline'));
      expect(result.stderr, contains('99th_percentile_frame_rasterizer_time'));
    });

    test('fails when a timeline summary has no frame samples', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-profile-');
      addTearDown(() => dir.delete(recursive: true));

      for (final key in _timelineKeys) {
        _writeProfileSummary(dir, key, buildMs: 4.2, rasterMs: 5.1);
      }
      _writeProfileSummary(
        dir,
        'streaming_detail_timeline',
        buildMs: 4.2,
        rasterMs: 5.1,
        frameCount: 0,
      );

      final result = await _runDartTool([
        'tool/check_profile_summaries.dart',
        dir.path,
        '8.3',
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('streaming_detail_timeline'));
      expect(result.stderr, contains('frame_count must be positive'));
    });

    test('fails when a required frame timing metric is missing', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-profile-');
      addTearDown(() => dir.delete(recursive: true));

      for (final key in _timelineKeys) {
        _writeProfileSummary(dir, key, buildMs: 4.2, rasterMs: 5.1);
      }
      _writeProfileSummary(
        dir,
        'session_cache_hydration_timeline',
        buildMs: 4.2,
        rasterMs: 5.1,
        omitKeys: ['99th_percentile_frame_rasterizer_time_millis'],
      );

      final result = await _runDartTool([
        'tool/check_profile_summaries.dart',
        dir.path,
        '8.3',
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('session_cache_hydration_timeline'));
      expect(result.stderr, contains('missing frame timing metric(s)'));
      expect(result.stderr, contains('99th_percentile_frame_rasterizer_time'));
    });
  });

  group('check_android_refresh_log.dart', () {
    test('parses first stdin log line as selection evidence', () async {
      final result = await _runDartTool(
        ['tool/check_android_refresh_log.dart', '-', '90'],
        stdinText:
            'I/MobilePiRefresh(123): event=refresh_mode_selected '
            'currentModeId=1 selectedModeId=2 currentRefreshRate=60.0 '
            'selectedRefreshRate=120.0 width=1080 height=2400\n',
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('refresh_mode_selected'));
      expect(result.stdout, contains('PASS selected refresh rate 120.00 Hz'));
    });

    test('fails when selected refresh rate is below threshold', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-refresh-');
      addTearDown(() => dir.delete(recursive: true));
      final log = File('${dir.path}/refresh.log')
        ..writeAsStringSync(
          'I/MobilePiRefresh(123): event=refresh_mode_already_selected '
          'modeId=1 refreshRate=60.0 width=1080 height=2400\n',
        );

      final result = await _runDartTool([
        'tool/check_android_refresh_log.dart',
        log.path,
        '90',
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('below the 90.00 Hz threshold'));
    });

    test('fails when refresh selection evidence is incomplete', () async {
      final result = await _runDartTool(
        ['tool/check_android_refresh_log.dart', '-', '90'],
        stdinText:
            'I/MobilePiRefresh(123): event=refresh_mode_selected '
            'selectedModeId=2 selectedRefreshRate=120.0\n',
      );

      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('Refresh selection evidence is incomplete'),
      );
      expect(result.stderr, contains('missing width, height'));
    });
  });

  group('check_android_lifecycle_log.dart', () {
    test('passes when resume forces reconnect', () async {
      final result = await _runDartTool(
        ['tool/check_android_lifecycle_log.dart', '-'],
        stdinText:
            'I/flutter (123): MobilePiLifecycle event=app_paused\n'
            'I/flutter (123): MobilePiLifecycle event=app_resumed\n'
            'I/flutter (123): MobilePiLifecycle event=app_resumed '
            'action=force_reconnect\n',
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(
        result.stdout,
        contains('PASS app pause/resume forced WebSocket reconnect'),
      );
    });

    test('fails when reconnect was not preceded by app pause', () async {
      final result = await _runDartTool(
        ['tool/check_android_lifecycle_log.dart', '-'],
        stdinText:
            'I/flutter (123): MobilePiLifecycle event=app_resumed\n'
            'I/flutter (123): MobilePiLifecycle event=app_resumed '
            'action=force_reconnect\n',
      );

      expect(result.exitCode, 1);
      expect(result.stderr, contains('No app_paused lifecycle event found'));
    });

    test(
      'fails when resume skips reconnect because tenant key is missing',
      () async {
        final result = await _runDartTool(
          ['tool/check_android_lifecycle_log.dart', '-'],
          stdinText:
              'I/flutter (123): MobilePiLifecycle event=app_paused\n'
              'I/flutter (123): MobilePiLifecycle event=app_resumed\n'
              'I/flutter (123): MobilePiLifecycle event=app_resumed '
              'action=skip_missing_tenant_key\n',
        );

        expect(result.exitCode, 1);
        expect(result.stderr, contains('tenant key is missing'));
      },
    );
  });

  group('check_android_device.dart', () {
    test('passes when requested adb device is ready', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-adb-');
      addTearDown(() => dir.delete(recursive: true));
      final devices = File('${dir.path}/devices.txt')
        ..writeAsStringSync(
          'List of devices attached\n'
          'android-serial\tdevice\n',
        );

      final result = await _runDartTool([
        'tool/check_android_device.dart',
        'android-serial',
        devices.path,
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('PASS Android device android-serial'));
    });

    test('fails when requested adb device is offline', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-adb-');
      addTearDown(() => dir.delete(recursive: true));
      final devices = File('${dir.path}/devices.txt')
        ..writeAsStringSync(
          'List of devices attached\n'
          'android-serial\toffline\n',
        );

      final result = await _runDartTool([
        'tool/check_android_device.dart',
        'android-serial',
        devices.path,
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('state "offline"; expected "device"'));
    });

    test('fails when requested adb device is missing', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-adb-');
      addTearDown(() => dir.delete(recursive: true));
      final devices = File('${dir.path}/devices.txt')
        ..writeAsStringSync(
          'List of devices attached\n'
          'other-device\tdevice\n',
        );

      final result = await _runDartTool([
        'tool/check_android_device.dart',
        'android-serial',
        devices.path,
      ]);

      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('Android device android-serial was not found'),
      );
      expect(result.stderr, contains('other-device(device)'));
    });
  });

  group('check_flutter_drive_log.dart', () {
    test('passes when a saved drive log reports success', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-drive-');
      addTearDown(() => dir.delete(recursive: true));
      final log = File('${dir.path}/drive.log')
        ..writeAsStringSync(
          '00:00 +0: profile streaming task detail timeline\n'
          '00:01 +2: All tests passed!\n',
        );

      final result = await _runDartTool([
        'tool/check_flutter_drive_log.dart',
        log.path,
        'profile streaming task detail timeline',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('PASS Flutter drive log'));
    });

    test('fails when a saved drive log contains a failure marker', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-drive-');
      addTearDown(() => dir.delete(recursive: true));
      final log = File('${dir.path}/drive.log')
        ..writeAsStringSync('00:01 -1: Some tests failed.\n');

      final result = await _runDartTool([
        'tool/check_flutter_drive_log.dart',
        log.path,
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('failure marker'));
    });

    test('fails when a saved drive log has no final success marker', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-drive-');
      addTearDown(() => dir.delete(recursive: true));
      final log = File('${dir.path}/drive.log')
        ..writeAsStringSync(
          '00:00 +0: profile streaming task detail timeline\n'
          '00:01 +1: profile dashboard scrolling timeline\n',
        );

      final result = await _runDartTool([
        'tool/check_flutter_drive_log.dart',
        log.path,
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('no final success marker'));
    });

    test('fails when a saved drive log omits a required marker', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-drive-');
      addTearDown(() => dir.delete(recursive: true));
      final log = File('${dir.path}/drive.log')
        ..writeAsStringSync('00:01 +2: All tests passed!\n');

      final result = await _runDartTool([
        'tool/check_flutter_drive_log.dart',
        log.path,
        'task detail gestures keep mobile conversation controls usable',
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('missing required marker'));
    });
  });

  group('check_device_acceptance_manifest.dart', () {
    test('writes and verifies the current device artifact set', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-manifest-');
      addTearDown(() => dir.delete(recursive: true));
      final artifacts = _writeDeviceArtifacts(dir);
      final manifest = '${artifacts.buildDir}/mobilepi-device-acceptance.json';

      final writeResult = await _runDartTool([
        'tool/check_device_acceptance_manifest.dart',
        '--write',
        manifest,
        'android-serial',
        '8.3',
        '90',
        artifacts.buildDir,
        artifacts.refreshLog,
        artifacts.lifecycleLog,
        artifacts.performanceLog,
        artifacts.interactionLog,
      ]);

      expect(writeResult.exitCode, 0, reason: writeResult.stderr as String);

      final checkResult = await _runDartTool([
        'tool/check_device_acceptance_manifest.dart',
        manifest,
        'android-serial',
        '8.3',
        '90',
        artifacts.buildDir,
        artifacts.refreshLog,
        artifacts.lifecycleLog,
        artifacts.performanceLog,
        artifacts.interactionLog,
      ]);

      expect(checkResult.exitCode, 0, reason: checkResult.stderr as String);
      expect(checkResult.stdout, contains('PASS device acceptance manifest'));
    });

    test('fails when the manifest uses the legacy schema', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-manifest-');
      addTearDown(() => dir.delete(recursive: true));
      final artifacts = _writeDeviceArtifacts(dir);
      final manifest = File(
        '${artifacts.buildDir}/mobilepi-device-acceptance.json',
      );

      final writeResult = await _runDartTool([
        'tool/check_device_acceptance_manifest.dart',
        '--write',
        manifest.path,
        'android-serial',
        '8.3',
        '90',
        artifacts.buildDir,
        artifacts.refreshLog,
        artifacts.lifecycleLog,
        artifacts.performanceLog,
        artifacts.interactionLog,
      ]);
      expect(writeResult.exitCode, 0, reason: writeResult.stderr as String);

      final decoded = jsonDecode(manifest.readAsStringSync());
      expect(decoded, isA<Map<String, dynamic>>());
      (decoded as Map<String, dynamic>)['schema'] = 2;
      manifest.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(decoded),
      );

      final result = await _runDartTool([
        'tool/check_device_acceptance_manifest.dart',
        manifest.path,
        'android-serial',
        '8.3',
        '90',
        artifacts.buildDir,
        artifacts.refreshLog,
        artifacts.lifecycleLog,
        artifacts.performanceLog,
        artifacts.interactionLog,
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('schema expected "3" but found "2"'));
    });

    test(
      'fails when an artifact changes after the manifest is written',
      () async {
        final dir = await Directory.systemTemp.createTemp('mobilepi-manifest-');
        addTearDown(() => dir.delete(recursive: true));
        final artifacts = _writeDeviceArtifacts(dir);
        final manifest =
            '${artifacts.buildDir}/mobilepi-device-acceptance.json';

        final writeResult = await _runDartTool([
          'tool/check_device_acceptance_manifest.dart',
          '--write',
          manifest,
          'android-serial',
          '8.3',
          '90',
          artifacts.buildDir,
          artifacts.refreshLog,
          artifacts.lifecycleLog,
          artifacts.performanceLog,
          artifacts.interactionLog,
        ]);
        expect(writeResult.exitCode, 0, reason: writeResult.stderr as String);

        await Future<void>.delayed(const Duration(milliseconds: 5));
        File(
          artifacts.performanceLog,
        ).writeAsStringSync('00:01 +2: All tests passed!\nnewer mixed log\n');

        final result = await _runDartTool([
          'tool/check_device_acceptance_manifest.dart',
          manifest,
          'android-serial',
          '8.3',
          '90',
          artifacts.buildDir,
          artifacts.refreshLog,
          artifacts.lifecycleLog,
          artifacts.performanceLog,
          artifacts.interactionLog,
        ]);

        expect(result.exitCode, 1);
        expect(result.stderr, contains('performanceLog bytes'));
      },
    );

    test(
      'fails when same-size artifact content changes with restored mtime',
      () async {
        final dir = await Directory.systemTemp.createTemp('mobilepi-manifest-');
        addTearDown(() => dir.delete(recursive: true));
        final artifacts = _writeDeviceArtifacts(dir);
        final manifest =
            '${artifacts.buildDir}/mobilepi-device-acceptance.json';

        final writeResult = await _runDartTool([
          'tool/check_device_acceptance_manifest.dart',
          '--write',
          manifest,
          'android-serial',
          '8.3',
          '90',
          artifacts.buildDir,
          artifacts.refreshLog,
          artifacts.lifecycleLog,
          artifacts.performanceLog,
          artifacts.interactionLog,
        ]);
        expect(writeResult.exitCode, 0, reason: writeResult.stderr as String);

        final log = File(artifacts.performanceLog);
        final originalModified = log.lastModifiedSync();
        final original = log.readAsStringSync();
        log.writeAsStringSync(original.replaceFirst('passed', 'pazzed'));
        log.setLastModifiedSync(originalModified);

        final result = await _runDartTool([
          'tool/check_device_acceptance_manifest.dart',
          manifest,
          'android-serial',
          '8.3',
          '90',
          artifacts.buildDir,
          artifacts.refreshLog,
          artifacts.lifecycleLog,
          artifacts.performanceLog,
          artifacts.interactionLog,
        ]);

        expect(result.exitCode, 1);
        expect(result.stderr, contains('performanceLog contentCrc32'));
      },
    );

    test(
      'fails when a profile summary changes after the manifest is written',
      () async {
        final dir = await Directory.systemTemp.createTemp('mobilepi-manifest-');
        addTearDown(() => dir.delete(recursive: true));
        final artifacts = _writeDeviceArtifacts(dir);
        final manifest =
            '${artifacts.buildDir}/mobilepi-device-acceptance.json';

        final writeResult = await _runDartTool([
          'tool/check_device_acceptance_manifest.dart',
          '--write',
          manifest,
          'android-serial',
          '8.3',
          '90',
          artifacts.buildDir,
          artifacts.refreshLog,
          artifacts.lifecycleLog,
          artifacts.performanceLog,
          artifacts.interactionLog,
        ]);
        expect(writeResult.exitCode, 0, reason: writeResult.stderr as String);

        await Future<void>.delayed(const Duration(milliseconds: 5));
        _writeProfileSummary(
          Directory(artifacts.buildDir),
          'dashboard_scroll_timeline',
          buildMs: 4.2,
          rasterMs: 7.7,
          frameCount: 48,
        );

        final result = await _runDartTool([
          'tool/check_device_acceptance_manifest.dart',
          manifest,
          'android-serial',
          '8.3',
          '90',
          artifacts.buildDir,
          artifacts.refreshLog,
          artifacts.lifecycleLog,
          artifacts.performanceLog,
          artifacts.interactionLog,
        ]);

        expect(result.exitCode, 1);
        expect(result.stderr, contains('dashboard_scroll_timelineSummary'));
      },
    );

    test(
      'fails when the profile APK changes after the manifest is written',
      () async {
        final dir = await Directory.systemTemp.createTemp('mobilepi-manifest-');
        addTearDown(() => dir.delete(recursive: true));
        final artifacts = _writeDeviceArtifacts(dir);
        final manifest =
            '${artifacts.buildDir}/mobilepi-device-acceptance.json';

        final writeResult = await _runDartTool([
          'tool/check_device_acceptance_manifest.dart',
          '--write',
          manifest,
          'android-serial',
          '8.3',
          '90',
          artifacts.buildDir,
          artifacts.refreshLog,
          artifacts.lifecycleLog,
          artifacts.performanceLog,
          artifacts.interactionLog,
        ]);
        expect(writeResult.exitCode, 0, reason: writeResult.stderr as String);

        File(
          '${artifacts.buildDir}/app/outputs/flutter-apk/app-profile.apk',
        ).writeAsStringSync('different-profile-apk');

        final result = await _runDartTool([
          'tool/check_device_acceptance_manifest.dart',
          manifest,
          'android-serial',
          '8.3',
          '90',
          artifacts.buildDir,
          artifacts.refreshLog,
          artifacts.lifecycleLog,
          artifacts.performanceLog,
          artifacts.interactionLog,
        ]);

        expect(result.exitCode, 1);
        expect(result.stderr, contains('profileApk'));
      },
    );
  });

  group('check_refactor_audit.dart', () {
    test('passes when every requirement bucket is represented', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-audit-');
      addTearDown(() => dir.delete(recursive: true));
      final audit = File('${dir.path}/audit.md')
        ..writeAsStringSync(
          _auditMarkdown(
            partialAreas: const ['P-6'],
            includeDeviceEvidenceMarkers: true,
          ),
        );

      final result = await _runDartTool([
        'tool/check_refactor_audit.dart',
        audit.path,
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('PASS refactor audit covers 16 areas'));
      expect(result.stdout, contains('15 proven, 1 partial'));
    });

    test('fails when a required requirement bucket is missing', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-audit-');
      addTearDown(() => dir.delete(recursive: true));
      final audit = File('${dir.path}/audit.md')
        ..writeAsStringSync(_auditMarkdown(omitAreas: const ['D-6']));

      final result = await _runDartTool([
        'tool/check_refactor_audit.dart',
        audit.path,
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('missing evidence matrix row for D-6'));
    });

    test(
      'fails when partial device evidence omits required commands',
      () async {
        final dir = await Directory.systemTemp.createTemp('mobilepi-audit-');
        addTearDown(() => dir.delete(recursive: true));
        final audit = File('${dir.path}/audit.md')
          ..writeAsStringSync(_auditMarkdown(partialAreas: const ['Network']));

        final result = await _runDartTool([
          'tool/check_refactor_audit.dart',
          audit.path,
        ]);

        expect(result.exitCode, 1);
        expect(
          result.stderr,
          contains(
            'Network device evidence requires marker: '
            'android-lifecycle-verify <device>',
          ),
        );
        expect(
          result.stderr,
          contains(
            'partial device evidence requires client-device-artifacts-check',
          ),
        );
      },
    );

    test('fails when remaining gaps omit a partial area name', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-audit-');
      addTearDown(() => dir.delete(recursive: true));
      final audit = File('${dir.path}/audit.md')
        ..writeAsStringSync(
          _auditMarkdown(
            partialAreas: const ['U-3'],
            includeDeviceEvidenceMarkers: true,
            includePartialGapMentions: false,
          ),
        );

      final result = await _runDartTool([
        'tool/check_refactor_audit.dart',
        audit.path,
      ]);

      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('Remaining Completion Gaps must mention partial area U-3'),
      );
    });

    test('complete mode passes only when every area is proven', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-audit-');
      addTearDown(() => dir.delete(recursive: true));
      final audit = File('${dir.path}/audit.md')
        ..writeAsStringSync(
          _auditMarkdown(
            includeRemainingGaps: false,
            includeDeviceEvidenceMarkers: true,
          ),
        );

      final result = await _runDartTool([
        'tool/check_refactor_audit.dart',
        audit.path,
        '--complete',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('PASS completion audit covers 16 areas'));
      expect(result.stdout, contains('16 proven, 0 partial'));
    });

    test('complete mode fails while remaining gaps are still listed', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-audit-');
      addTearDown(() => dir.delete(recursive: true));
      final audit = File('${dir.path}/audit.md')
        ..writeAsStringSync(_auditMarkdown(includeDeviceEvidenceMarkers: true));

      final result = await _runDartTool([
        'tool/check_refactor_audit.dart',
        audit.path,
        '--complete',
      ]);

      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('completion requires Remaining Completion Gaps to be empty'),
      );
    });

    test('complete mode fails without device evidence markers', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-audit-');
      addTearDown(() => dir.delete(recursive: true));
      final audit = File('${dir.path}/audit.md')
        ..writeAsStringSync(_auditMarkdown(includeRemainingGaps: false));

      final result = await _runDartTool([
        'tool/check_refactor_audit.dart',
        audit.path,
        '--complete',
      ]);

      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains(
          'P-6 device evidence requires marker: '
          'client-device-acceptance <device> 8.3 90',
        ),
      );
    });

    test('complete mode fails while any area remains partial', () async {
      final dir = await Directory.systemTemp.createTemp('mobilepi-audit-');
      addTearDown(() => dir.delete(recursive: true));
      final audit = File('${dir.path}/audit.md')
        ..writeAsStringSync(
          _auditMarkdown(
            partialAreas: const ['P-6'],
            includeDeviceEvidenceMarkers: true,
          ),
        );

      final result = await _runDartTool([
        'tool/check_refactor_audit.dart',
        audit.path,
        '--complete',
      ]);

      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('completion requires no partial areas; still partial: P-6'),
      );
    });
  });

  group('Justfile acceptance recipes', () {
    test(
      'device acceptance persists profile and refresh evidence artifacts',
      () {
        final justfile = File('../Justfile').readAsStringSync();

        expect(justfile, contains('client-device-acceptance device'));
        expect(justfile, contains('mkdir -p client/build'));
        expect(
          justfile,
          contains('dart run tool/check_android_device.dart "{{device}}"'),
        );
        expect(justfile, contains('cd client && flutter build apk --profile'));
        expect(
          justfile,
          contains('FLUTTER_TEST_OUTPUTS_DIR=build flutter drive'),
        );
        expect(justfile, contains('adb -s "{{device}}" forward --remove-all'));
        expect(justfile, contains('--no-dds'));
        expect(justfile, contains('--keep-app-running'));
        expect(justfile, contains('--host-vmservice-port=12345'));
        expect(justfile, contains('--host-vmservice-port=12347'));
        expect(justfile, contains('--host-vmservice-port=12348'));
        expect(
          justfile,
          contains('--dart-define=MOBILEPI_PROFILE_SCENARIO=streaming_detail'),
        );
        expect(
          justfile,
          contains('--dart-define=MOBILEPI_PROFILE_SCENARIO=dashboard_scroll'),
        );
        expect(
          justfile,
          contains(
            '--dart-define=MOBILEPI_PROFILE_SCENARIO=session_cache_hydration',
          ),
        );
        expect(justfile, contains('tee -a "'));
        expect(justfile, contains('build/mobilepi-performance-drive.log'));
        expect(
          justfile,
          contains('dart run tool/check_profile_summaries.dart build'),
        );
        expect(
          justfile,
          contains(
            'dart run tool/check_flutter_drive_log.dart '
            'build/mobilepi-performance-drive.log',
          ),
        );
        expect(justfile, contains('profile streaming task detail timeline'));
        expect(justfile, contains('profile dashboard scrolling timeline'));
        expect(justfile, contains('profile session cache hydration timeline'));
        expect(
          justfile,
          contains(
            'flutter drive --profile --no-dds --keep-app-running '
            '--host-vmservice-port=12346 -d "{{device}}" '
            '--driver=test_driver/perf_driver.dart '
            '--target=integration_test/mobilepi_interaction_test.dart',
          ),
        );
        expect(justfile, contains('tee build/mobilepi-interaction-drive.log'));
        expect(
          justfile,
          contains(
            'dart run tool/check_flutter_drive_log.dart '
            'build/mobilepi-interaction-drive.log',
          ),
        );
        expect(
          justfile,
          contains('mobile dashboard actions run on-device gesture paths'),
        );
        expect(
          justfile,
          contains(
            'task detail gestures keep mobile conversation controls usable',
          ),
        );
        expect(justfile, contains('tee client/build/android-refresh.log'));
        expect(
          justfile,
          contains('dart run tool/check_android_refresh_log.dart -'),
        );
        expect(justfile, contains('shell input keyevent HOME'));
        expect(
          justfile,
          contains(
            'shell am start -n com.example.mobilepi_client/.MainActivity',
          ),
        );
        expect(justfile, isNot(contains('shell monkey -p')));
        expect(justfile, contains('tee client/build/android-lifecycle.log'));
        expect(
          justfile,
          contains('dart run tool/check_android_lifecycle_log.dart -'),
        );
        expect(
          justfile,
          contains(
            'dart run tool/check_device_acceptance_manifest.dart --write '
            'build/mobilepi-device-acceptance.json "{{device}}"',
          ),
        );
      },
    );

    test('mobile interaction probe is available as a device recipe', () {
      final justfile = File('../Justfile').readAsStringSync();

      expect(
        justfile,
        contains(
          'client-interaction-test device '
          'log="build/mobilepi-interaction-drive.log"',
        ),
      );
      expect(
        justfile,
        contains('--target=integration_test/mobilepi_interaction_test.dart'),
      );
    });

    test('saved device artifacts can be checked independently', () {
      final justfile = File('../Justfile').readAsStringSync();

      expect(
        justfile,
        contains(
          'client-device-artifacts-check device build_dir="build" '
          'refresh_log="build/android-refresh.log" '
          'lifecycle_log="build/android-lifecycle.log" '
          'performance_log="build/mobilepi-performance-drive.log" '
          'interaction_log="build/mobilepi-interaction-drive.log"',
        ),
      );
      expect(
        justfile,
        contains(
          'dart run tool/check_profile_summaries.dart "{{build_dir}}" '
          '"{{budget_ms}}"',
        ),
      );
      expect(
        justfile,
        contains(
          'dart run tool/check_android_refresh_log.dart "{{refresh_log}}" '
          '"{{min_hz}}"',
        ),
      );
      expect(
        justfile,
        contains(
          'dart run tool/check_android_lifecycle_log.dart "{{lifecycle_log}}"',
        ),
      );
      expect(
        justfile,
        contains(
          'dart run tool/check_flutter_drive_log.dart "{{performance_log}}"',
        ),
      );
      expect(justfile, contains('profile dashboard scrolling timeline'));
      expect(
        justfile,
        contains(
          'dart run tool/check_flutter_drive_log.dart "{{interaction_log}}"',
        ),
      );
      expect(
        justfile,
        contains('mobile dashboard actions run on-device gesture paths'),
      );
      expect(
        justfile,
        contains(
          'dart run tool/check_device_acceptance_manifest.dart "{{manifest}}" '
          '"{{device}}" "{{budget_ms}}" "{{min_hz}}"',
        ),
      );
    });

    test('android lifecycle verifier is available as a device recipe', () {
      final justfile = File('../Justfile').readAsStringSync();

      expect(justfile, contains('android-device-check device:'));
      expect(justfile, contains('refactor-completion-check audit='));
      expect(
        justfile,
        contains('tool/check_refactor_audit.dart "../{{audit}}" --complete'),
      );
      expect(justfile, contains('android-lifecycle-check log_file:'));
      expect(justfile, contains('android-lifecycle-verify device=""'));
      expect(
        justfile,
        contains('dart run tool/check_android_lifecycle_log.dart'),
      );
    });
  });
}

const _timelineKeys = [
  'streaming_detail_timeline',
  'dashboard_scroll_timeline',
  'session_cache_hydration_timeline',
];

const _auditAreas = [
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

String _auditMarkdown({
  List<String> omitAreas = const [],
  List<String> partialAreas = const [],
  bool includeRemainingGaps = true,
  bool includePartialGapMentions = true,
  bool includeDeviceEvidenceMarkers = false,
}) {
  final buffer = StringBuffer()
    ..writeln('# MobilePi Refactor Goal Audit')
    ..writeln()
    ..writeln('## Current Evidence Matrix')
    ..writeln()
    ..writeln('| Area | Requirement | Current evidence | Status |')
    ..writeln('| --- | --- | --- | --- |');
  for (final area in _auditAreas) {
    if (omitAreas.contains(area)) continue;
    final status = partialAreas.contains(area)
        ? 'Partial: needs device verification'
        : 'Proven by tests';
    buffer.writeln('| $area | requirement | evidence | $status |');
  }
  buffer
    ..writeln()
    ..writeln('## Remaining Completion Gaps')
    ..writeln();
  if (includeRemainingGaps) {
    if (includePartialGapMentions && partialAreas.isNotEmpty) {
      for (final area in partialAreas) {
        buffer.writeln('- $area: Device verification remains for this row.');
      }
    } else {
      buffer.writeln('- Device verification remains for partial rows.');
    }
  }
  buffer
    ..writeln()
    ..writeln('## Useful Verification Commands');
  if (includeDeviceEvidenceMarkers) {
    buffer
      ..writeln()
      ..writeln(
        'nix develop --command just client-device-acceptance <device> 8.3 90',
      )
      ..writeln('nix develop --command just android-device-check <device>')
      ..writeln('nix develop --command just android-refresh-verify <device> 90')
      ..writeln('nix develop --command just client-interaction-test <device>')
      ..writeln('nix develop --command just android-lifecycle-verify <device>')
      ..writeln(
        'nix develop --command just client-device-artifacts-check <device> build build/android-refresh.log build/android-lifecycle.log build/mobilepi-performance-drive.log build/mobilepi-interaction-drive.log 8.3 90 build/mobilepi-device-acceptance.json',
      )
      ..writeln('client/build/android-refresh.log')
      ..writeln('client/build/android-lifecycle.log')
      ..writeln('build/mobilepi-device-acceptance.json')
      ..writeln('streaming_detail_timeline.timeline_summary.json')
      ..writeln('dashboard_scroll_timeline.timeline_summary.json')
      ..writeln('session_cache_hydration_timeline.timeline_summary.json')
      ..writeln('app-profile.apk')
      ..writeln('mobilepi-performance-drive.log')
      ..writeln('mobilepi-interaction-drive.log')
      ..writeln('tool/check_android_device.dart')
      ..writeln('tool/check_android_refresh_log.dart')
      ..writeln('tool/check_android_lifecycle_log.dart')
      ..writeln('tool/check_flutter_drive_log.dart')
      ..writeln('tool/check_device_acceptance_manifest.dart')
      ..writeln('integration_test/mobilepi_interaction_test.dart');
  }
  return buffer.toString();
}

void _writeProfileSummary(
  Directory dir,
  String key, {
  required double buildMs,
  required double rasterMs,
  int frameCount = 24,
  List<String> omitKeys = const [],
}) {
  final file = File('${dir.path}/$key.timeline_summary.json');
  final summary = {
    'frame_count': frameCount,
    'frame_rasterizer_count': frameCount,
    'average_frame_build_time_millis': buildMs,
    '90th_percentile_frame_build_time_millis': buildMs + 0.4,
    '99th_percentile_frame_build_time_millis': buildMs + 0.7,
    'average_frame_rasterizer_time_millis': rasterMs,
    '90th_percentile_frame_rasterizer_time_millis': rasterMs + 0.6,
    '99th_percentile_frame_rasterizer_time_millis': rasterMs + 0.9,
  }..removeWhere((key, _) => omitKeys.contains(key));
  file.writeAsStringSync(jsonEncode(summary));
}

_DeviceArtifacts _writeDeviceArtifacts(Directory root) {
  final buildDir = Directory('${root.path}/build')..createSync();
  for (final key in _timelineKeys) {
    _writeProfileSummary(buildDir, key, buildMs: 4.2, rasterMs: 5.1);
  }
  final refreshLog = File('${buildDir.path}/android-refresh.log')
    ..writeAsStringSync('refresh\n');
  final lifecycleLog = File('${buildDir.path}/android-lifecycle.log')
    ..writeAsStringSync('lifecycle\n');
  final performanceLog = File('${buildDir.path}/mobilepi-performance-drive.log')
    ..writeAsStringSync('00:01 +2: All tests passed!\n');
  final interactionLog = File('${buildDir.path}/mobilepi-interaction-drive.log')
    ..writeAsStringSync('00:01 +2: All tests passed!\n');
  File('${buildDir.path}/app/outputs/flutter-apk/app-profile.apk')
    ..createSync(recursive: true)
    ..writeAsStringSync('fake-profile-apk');

  return _DeviceArtifacts(
    buildDir: buildDir.path,
    refreshLog: refreshLog.path,
    lifecycleLog: lifecycleLog.path,
    performanceLog: performanceLog.path,
    interactionLog: interactionLog.path,
  );
}

class _DeviceArtifacts {
  const _DeviceArtifacts({
    required this.buildDir,
    required this.refreshLog,
    required this.lifecycleLog,
    required this.performanceLog,
    required this.interactionLog,
  });

  final String buildDir;
  final String refreshLog;
  final String lifecycleLog;
  final String performanceLog;
  final String interactionLog;
}

Future<ProcessResult> _runDartTool(
  List<String> arguments, {
  String? stdinText,
}) async {
  final process = await Process.start(
    'dart',
    arguments,
    workingDirectory: Directory.current.path,
  );
  if (stdinText != null) {
    process.stdin.write(stdinText);
  }
  await process.stdin.close();

  final stdoutText = process.stdout.transform(utf8.decoder).join();
  final stderrText = process.stderr.transform(utf8.decoder).join();
  final exitCode = await process.exitCode;

  return ProcessResult(
    process.pid,
    exitCode,
    await stdoutText,
    await stderrText,
  );
}
