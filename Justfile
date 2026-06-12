set dotenv-load := true
set shell := ["bash", "-uc"]

web_host := env_var_or_default("MOBILE_PI_WEB_HOST", "127.0.0.1")
web_port := env_var_or_default("MOBILE_PI_WEB_PORT", "8082")
hub_url := env_var_or_default("MOBILE_PI_HUB_WS_URL", "ws://localhost:8080/ws")
hub_port := env_var_or_default("MOBILE_PI_HUB_PORT", "8080")
tenant_key := env_var_or_default("MOBILE_PI_TENANT_KEY", "")

default:
    @just --list

# Start the MobilePi Hub server.
hub:
    cd hub && MOBILE_PI_TENANT_KEY="{{tenant_key}}" dart run bin/hub.dart {{hub_port}}

# Start the local Daemon and register it with Hub.
daemon:
    cd node && MOBILE_PI_TENANT_KEY="{{tenant_key}}" dart run bin/node.dart {{hub_url}}

# Start the Flutter web client through flutter run -d web-server.
client-web:
    cd client && flutter run -d web-server --web-hostname={{web_host}} --web-port={{web_port}}

# Start the Flutter client on a specific device, default web-server.
client device="web-server":
    if [ "{{device}}" = "web-server" ]; then \
      cd client && flutter run -d web-server --web-hostname={{web_host}} --web-port={{web_port}}; \
    else \
      cd client && flutter run -d "{{device}}"; \
    fi

# Run the Flutter client in profile mode and save a Perfetto timeline trace.
client-profile device trace="build/mobilepi-profile-trace.binpb":
    mkdir -p "$(dirname "{{trace}}")"
    cd client && flutter run --profile -d "{{device}}" --trace-to-file="../{{trace}}" --endless-trace-buffer --trace-systrace

# Run the streaming detail performance probe on a device in profile mode.
client-profile-test device log="build/mobilepi-performance-drive.log":
    cd client && mkdir -p "$(dirname "{{log}}")"
    cd client && rm -f build/streaming_detail_timeline* build/dashboard_scroll_timeline* build/session_cache_hydration_timeline*
    cd client && : > "{{log}}"
    adb -s "{{device}}" forward --remove-all || true
    cd client && bash -o pipefail -c 'FLUTTER_TEST_OUTPUTS_DIR=build flutter drive --profile --no-dds --keep-app-running --host-vmservice-port=12345 -d "{{device}}" --dart-define=MOBILEPI_PROFILE_SCENARIO=streaming_detail --driver=test_driver/perf_driver.dart --target=integration_test/mobilepi_performance_test.dart 2>&1 | tee -a "{{log}}"'
    adb -s "{{device}}" forward --remove-all || true
    cd client && bash -o pipefail -c 'FLUTTER_TEST_OUTPUTS_DIR=build flutter drive --profile --no-dds --keep-app-running --host-vmservice-port=12347 -d "{{device}}" --dart-define=MOBILEPI_PROFILE_SCENARIO=dashboard_scroll --driver=test_driver/perf_driver.dart --target=integration_test/mobilepi_performance_test.dart 2>&1 | tee -a "{{log}}"'
    adb -s "{{device}}" forward --remove-all || true
    cd client && bash -o pipefail -c 'FLUTTER_TEST_OUTPUTS_DIR=build flutter drive --profile --no-dds --keep-app-running --host-vmservice-port=12348 -d "{{device}}" --dart-define=MOBILEPI_PROFILE_SCENARIO=session_cache_hydration --driver=test_driver/perf_driver.dart --target=integration_test/mobilepi_performance_test.dart 2>&1 | tee -a "{{log}}"'

# Run the mobile interaction gesture probe on a device in profile mode.
client-interaction-test device log="build/mobilepi-interaction-drive.log":
    cd client && mkdir -p "$(dirname "{{log}}")"
    adb -s "{{device}}" forward --remove-all || true
    cd client && bash -o pipefail -c 'flutter drive --profile --no-dds --keep-app-running --host-vmservice-port=12346 -d "{{device}}" --driver=test_driver/perf_driver.dart --target=integration_test/mobilepi_interaction_test.dart 2>&1 | tee "{{log}}"'

# Fail fast unless the requested Android device is attached and ready.
android-device-check device:
    cd client && dart run tool/check_android_device.dart "{{device}}"

# Check profile timeline summaries against an 8.3ms frame budget.
client-profile-check build_dir="client/build" budget_ms="8.3":
    cd client && dart run tool/check_profile_summaries.dart "../{{build_dir}}" "{{budget_ms}}"

# Check the refactor audit matrix covers every output.md requirement bucket.
refactor-audit-check audit=".trellis/workspace/bubu/mobilepi-refactor-audit.md":
    cd client && dart run tool/check_refactor_audit.dart "../{{audit}}"

# Check whether the refactor goal is ready to mark complete.
refactor-completion-check audit=".trellis/workspace/bubu/mobilepi-refactor-audit.md":
    cd client && dart run tool/check_refactor_audit.dart "../{{audit}}" --complete

# Run all non-device acceptance checks for the refactor goal.
local-acceptance:
    cd shared && dart analyze
    cd hub && dart analyze
    cd hub && dart test
    cd node && dart analyze
    cd node && dart test test/agent test/persistence test/daemon_sync_pi_only_test.dart test/normalize_hub_url_test.dart
    cd client && flutter analyze
    cd client && flutter test
    cd client && flutter build apk --debug
    cd client && flutter build apk --profile
    cd client && dart run tool/check_refactor_audit.dart "../.trellis/workspace/bubu/mobilepi-refactor-audit.md"

# Run the Android/device acceptance probe: profile timelines, frame budget, and high-refresh logs.
client-device-acceptance device budget_ms="8.3" min_hz="90":
    mkdir -p client/build
    cd client && dart run tool/check_android_device.dart "{{device}}"
    cd client && flutter build apk --profile
    adb -s "{{device}}" logcat -c
    just client-profile-test "{{device}}" build/mobilepi-performance-drive.log
    cd client && dart run tool/check_profile_summaries.dart build "{{budget_ms}}"
    cd client && dart run tool/check_flutter_drive_log.dart build/mobilepi-performance-drive.log "profile streaming task detail timeline" "profile dashboard scrolling timeline" "profile session cache hydration timeline"
    adb -s "{{device}}" forward --remove-all || true
    cd client && bash -o pipefail -c 'flutter drive --profile --no-dds --keep-app-running --host-vmservice-port=12346 -d "{{device}}" --driver=test_driver/perf_driver.dart --target=integration_test/mobilepi_interaction_test.dart 2>&1 | tee build/mobilepi-interaction-drive.log'
    cd client && dart run tool/check_flutter_drive_log.dart build/mobilepi-interaction-drive.log "mobile dashboard actions run on-device gesture paths" "task detail gestures keep mobile conversation controls usable"
    adb -s "{{device}}" logcat -d -s MobilePiRefresh | tee client/build/android-refresh.log | (cd client && dart run tool/check_android_refresh_log.dart - "{{min_hz}}")
    adb -s "{{device}}" shell am start -n com.example.mobilepi_client/.MainActivity >/dev/null
    sleep 1
    adb -s "{{device}}" shell input keyevent HOME
    sleep 1
    adb -s "{{device}}" shell am start -n com.example.mobilepi_client/.MainActivity >/dev/null
    sleep 1
    adb -s "{{device}}" logcat -d | tee client/build/android-lifecycle.log | (cd client && dart run tool/check_android_lifecycle_log.dart -)
    cd client && dart run tool/check_device_acceptance_manifest.dart --write build/mobilepi-device-acceptance.json "{{device}}" "{{budget_ms}}" "{{min_hz}}" build build/android-refresh.log build/android-lifecycle.log build/mobilepi-performance-drive.log build/mobilepi-interaction-drive.log

# Check saved device acceptance artifacts after a profile run.
client-device-artifacts-check device build_dir="build" refresh_log="build/android-refresh.log" lifecycle_log="build/android-lifecycle.log" performance_log="build/mobilepi-performance-drive.log" interaction_log="build/mobilepi-interaction-drive.log" budget_ms="8.3" min_hz="90" manifest="build/mobilepi-device-acceptance.json":
    cd client && dart run tool/check_profile_summaries.dart "{{build_dir}}" "{{budget_ms}}"
    cd client && dart run tool/check_android_refresh_log.dart "{{refresh_log}}" "{{min_hz}}"
    cd client && dart run tool/check_android_lifecycle_log.dart "{{lifecycle_log}}"
    cd client && dart run tool/check_flutter_drive_log.dart "{{performance_log}}" "profile streaming task detail timeline" "profile dashboard scrolling timeline" "profile session cache hydration timeline"
    cd client && dart run tool/check_flutter_drive_log.dart "{{interaction_log}}" "mobile dashboard actions run on-device gesture paths" "task detail gestures keep mobile conversation controls usable"
    cd client && dart run tool/check_device_acceptance_manifest.dart "{{manifest}}" "{{device}}" "{{budget_ms}}" "{{min_hz}}" "{{build_dir}}" "{{refresh_log}}" "{{lifecycle_log}}" "{{performance_log}}" "{{interaction_log}}"

# Check saved Android lifecycle logs for foreground resume reconnect evidence.
android-lifecycle-check log_file:
    cd client && dart run tool/check_android_lifecycle_log.dart "../{{log_file}}"

# Background and foreground the Android app, then verify resume reconnect logs.
android-lifecycle-verify device="":
    if [ -n "{{device}}" ]; then \
      adb -s "{{device}}" logcat -c; \
      adb -s "{{device}}" shell am start -n com.example.mobilepi_client/.MainActivity >/dev/null; \
      sleep 1; \
      adb -s "{{device}}" shell input keyevent HOME; \
      sleep 1; \
      adb -s "{{device}}" shell am start -n com.example.mobilepi_client/.MainActivity >/dev/null; \
      sleep 1; \
      adb -s "{{device}}" logcat -d | (cd client && dart run tool/check_android_lifecycle_log.dart -); \
    else \
      adb logcat -c; \
      adb shell am start -n com.example.mobilepi_client/.MainActivity >/dev/null; \
      sleep 1; \
      adb shell input keyevent HOME; \
      sleep 1; \
      adb shell am start -n com.example.mobilepi_client/.MainActivity >/dev/null; \
      sleep 1; \
      adb logcat -d | (cd client && dart run tool/check_android_lifecycle_log.dart -); \
    fi

# Print Android refresh-mode selection logs emitted by MainActivity.
android-refresh-log device="":
    if [ -n "{{device}}" ]; then \
      adb -s "{{device}}" logcat -d -s MobilePiRefresh; \
    else \
      adb logcat -d -s MobilePiRefresh; \
    fi

# Check saved Android refresh-mode logs against a minimum selected refresh rate.
android-refresh-check log_file min_hz="90":
    cd client && dart run tool/check_android_refresh_log.dart "../{{log_file}}" "{{min_hz}}"

# Fetch and check Android refresh-mode logs against a minimum selected refresh rate.
android-refresh-verify device="" min_hz="90":
    if [ -n "{{device}}" ]; then \
      adb -s "{{device}}" logcat -d -s MobilePiRefresh | (cd client && dart run tool/check_android_refresh_log.dart - "{{min_hz}}"); \
    else \
      adb logcat -d -s MobilePiRefresh | (cd client && dart run tool/check_android_refresh_log.dart - "{{min_hz}}"); \
    fi

# Build the Flutter Android release APK for arm64-v8a devices.
android-arm64:
    cd client && flutter build apk --release --split-per-abi
    @echo "Built client/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"

# Print the commands normally used during local web development.
dev:
    @echo "Run these in separate terminals:"
    @echo "  just hub"
    @echo "  just daemon"
    @echo "  just client-web"
