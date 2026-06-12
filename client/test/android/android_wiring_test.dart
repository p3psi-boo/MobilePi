import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android manifest enables Impeller for smoother frame pacing', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(
      manifest,
      contains('android:name="io.flutter.embedding.android.EnableImpeller"'),
    );
    expect(manifest, contains('android:value="true"'));
  });

  test('MainActivity requests and logs the highest matching refresh mode', () {
    final activity = File(
      'android/app/src/main/kotlin/com/example/mobilepi_client/MainActivity.kt',
    ).readAsStringSync();

    expect(activity, contains('onCreate'));
    expect(activity, contains('onWindowFocusChanged'));
    expect(activity, contains('preferHighestRefreshRate()'));
    expect(activity, contains('supportedModes'));
    expect(activity, contains('physicalWidth == currentMode.physicalWidth'));
    expect(activity, contains('physicalHeight == currentMode.physicalHeight'));
    expect(activity, contains('maxByOrNull { it.refreshRate }'));
    expect(activity, contains('preferredDisplayModeId = bestMode.modeId'));
    expect(activity, contains('MobilePiRefresh'));
    expect(activity, contains('event=refresh_mode_selected'));
    expect(activity, contains('event=refresh_mode_already_selected'));
    expect(activity, contains('event=refresh_mode_skip'));
  });

  test('device lifecycle recipes launch the declared MainActivity', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final justfile = File('../Justfile').readAsStringSync();

    expect(gradle, contains('applicationId = "com.example.mobilepi_client"'));
    expect(manifest, contains('android:name=".MainActivity"'));
    expect(
      justfile,
      contains('shell am start -n com.example.mobilepi_client/.MainActivity'),
    );
    expect(justfile, isNot(contains('shell monkey -p')));
  });
}
