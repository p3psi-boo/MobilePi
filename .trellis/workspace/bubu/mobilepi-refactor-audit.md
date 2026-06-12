# MobilePi Refactor Goal Audit

Date: 2026-06-10

Source objective: `output.md` comprehensive refactor plan.

This file tracks evidence for the active goal. "Proven" means there is current
code plus an automated test or an executable verification command. "Partial"
means implementation exists but the evidence does not yet cover the full
acceptance scope from `output.md`.

## Current Evidence Matrix

| Area | Requirement | Current evidence | Status |
| --- | --- | --- | --- |
| P-1 | Split hot task updates away from global `notifyListeners()` | `NodeProvider.taskListenable`, `recentTasksListenable`; provider tests for coalesced task notifications, unrelated task isolation, recent-list structural updates, and global listener silence during streaming increments | Proven by unit tests |
| P-2 | Streaming uses plain text; completed/history Markdown is cached | `TaskDetailScreen` uses `_LivePlainText` for live output and `PiMarkdown` after completion; widget tests cover live plain text, repeated markdown-heavy deltas keeping `PiMarkdown` cache cold, and bounded cache reuse | Proven by widget tests |
| P-3 | Fixed cadence for text/tool/thinking/progress incremental updates | `_isRunningIncrementalUpdate` covers text, toolCall, toolResult, thinking, status label, progress, line counts; provider tests cover coalescing and no global notify | Proven by unit tests |
| P-4 | Scroll path avoids page `setState`, disables keep-alives, keeps repaint boundaries, removes expensive shadows | `TaskDetailScreen` uses independent notifiers and `SliverChildBuilderDelegate(addAutomaticKeepAlives: false, addRepaintBoundaries: true)`; visual token guard forbids shadows/elevation in screens/widgets | Proven by widget/static tests |
| P-5 | Local SQLite `SessionCache` hydrates cold start and persists task snapshots | `SessionCache` drift service; provider hydrate/persist tests; cache service tests | Proven by unit tests |
| P-6 | Remove streaming truncation, bound logs, request Android high refresh, enable Impeller | Long streaming provider test; `LogBuffer.capacity` test; Android manifest/MainActivity implementation; static Android wiring test for Impeller, high-refresh mode selection, focus reapply, and `MobilePiRefresh` logging; `flutter build apk --debug` produced `client/build/app/outputs/flutter-apk/app-debug.apk` on 2026-06-10 | Partial: build/static wiring evidence exists; actual refresh-rate selection still needs device verification |
| U-1 | Design tokens replace hard-coded visual noise | `AppTokens`, theme wiring, screen/widget static guard against hard-coded colors/shadows | Proven by static/widget tests |
| U-2 | Conversation-first create flow and automatic composer routing | `TaskCreateScreen` blank composer; provider tests for `sendComposerMessage`; screen test for no up-front node/model form | Proven by unit/widget tests |
| U-3 | Mobile-native actions: inline waiting actions, long press sheet, log drawer, edge-swipe, keyboard-safe composer | Dashboard/task detail implementations; widget tests cover inline waiting actions, no `Dismissible`, long-press action sheet, panic from sheet, in-context log drawer, edge-swipe back, keyboard-safe composer padding, and 44dp bottom composer/log touch targets; `integration_test/mobilepi_interaction_test.dart` exercises the dashboard and detail gesture paths for device/profile runs | Partial: core flows, target sizes, and a device integration probe exist; gesture ergonomics still needs real device execution/manual review |
| D-1 | Replay globally ordered across streams | `NodeDatabase.eventsAfter` global event scan; persistence tests | Proven by node tests |
| D-2 | `truncatedStreams` + snapshot + `hasMore` pagination | Node DB/daemon/client implementation; node and provider tests | Proven by node/client tests |
| D-3 | Unified `(streamId, seq)` protocol dedupe and historical `sourceIndex` dedupe | client cursor gate; historical sourceIndex model/parser/provider tests; spec contract | Proven by node/client tests |
| D-4 | Lossless parts model for toolCall/toolResult; no parallel `toolEvents` truth | node session parser, daemon live events, client model/provider/task rendering tests | Proven by node/client tests |
| D-5 | Parser robustness: bad JSON lines, strict byte tail, byte-offset dedupe | RPC/session/daemon tests cover malformed JSON/session lines and tail handling | Proven by node tests |
| D-6 | No 24KB streaming truncation | provider long-output test; protocol spec forbids truncation | Proven by unit tests |
| Network | Faster heartbeat and foreground reconnect/resume | `WebSocketService` 15s/2 defaults; real local WebSocket tests cover half-open disconnect and healthy pong keep-alive; provider tests cover `refresh()` / `onAppResumed()` force reconnect with resume cursors; app lifecycle widget test proves `AppLifecycleState.paused` logs `app_paused` and `AppLifecycleState.resumed` reaches the provider; `tool/check_android_lifecycle_log.dart` requires a device logcat sequence of `app_paused` followed by `app_resumed action=force_reconnect`, and `just android-lifecycle-verify` drives start -> HOME -> start | Partial: core network/app lifecycle behavior and device verifier exist; mobile OS background/foreground behavior still needs real Android execution evidence |

## Remaining Completion Gaps

- P-6: Capture real performance evidence from Flutter DevTools/profile mode for
  streaming task detail build/raster time, dashboard scrolling, and cold-start
  cache hydration. Run the debug/profile APK on a high-refresh Android device
  and verify the selected display mode / frame pacing. `MainActivity` logs
  `MobilePiRefresh` refresh mode events; use
  `nix develop --command just client-device-acceptance <device> 8.3 90` to run
  the full evidence path. Unit/widget/static tests prove topology and platform
  wiring, not that a specific device accepts the requested mode or meets frame
  budget.
- U-3: Execute the mobile interaction probe on a real Android device and record
  the resulting `mobilepi-interaction-drive.log`. Widget tests cover target
  sizes and gesture wiring, but the one-handed gesture ergonomics and native
  feel still need device execution/manual review.
- Network: Execute Android background/foreground lifecycle verification on a
  real device and record `android-lifecycle.log`. Local WebSocket and lifecycle
  widget tests prove the code path, but mobile OS app backgrounding/relaunch
  behavior still needs logcat evidence from Android.
- Perform a requirement-by-requirement final audit against `output.md` before
  calling the active goal complete. Current evidence is strong but not yet full
  acceptance proof for device-level UI/UX and performance claims.

## Useful Verification Commands

```bash
cd client && nix develop --command flutter analyze
cd client && nix develop --command flutter test
cd client && nix develop --command flutter test test/screens/dashboard_screen_test.dart
cd client && nix develop --command flutter test test/screens/task_detail_screen_test.dart
cd client && nix develop --command flutter test test/services/websocket_service_url_test.dart
cd node && nix develop --command dart test test/agent test/persistence test/daemon_sync_pi_only_test.dart test/normalize_hub_url_test.dart
cd client && nix develop --command flutter build apk --debug
cd client && nix develop --command flutter build apk --profile
nix develop --command just local-acceptance
nix develop --command just refactor-audit-check
nix develop --command just refactor-completion-check
nix develop --command just client-device-acceptance <device> 8.3 90
nix develop --command just android-device-check <device>
nix develop --command just client-interaction-test <device>
nix develop --command just android-refresh-log <device>
nix develop --command just android-refresh-verify <device> 90
nix develop --command just client-profile <device>
nix develop --command just client-profile-test <device>
nix develop --command just client-profile-check client/build 8.3
nix develop --command just android-lifecycle-verify <device>
nix develop --command just android-lifecycle-check client/build/android-lifecycle.log
nix develop --command just client-device-artifacts-check <device> build build/android-refresh.log build/android-lifecycle.log build/mobilepi-performance-drive.log build/mobilepi-interaction-drive.log 8.3 90 build/mobilepi-device-acceptance.json
client/build/streaming_detail_timeline.timeline_summary.json
client/build/dashboard_scroll_timeline.timeline_summary.json
client/build/session_cache_hydration_timeline.timeline_summary.json
client/build/app/outputs/flutter-apk/app-profile.apk
tool/check_android_device.dart
tool/check_flutter_drive_log.dart
tool/check_device_acceptance_manifest.dart
```

## Latest Verification Notes

- 2026-06-10: `cd client && nix develop --command flutter build apk --debug`
  succeeded after adding the profile integration probe and produced
  `client/build/app/outputs/flutter-apk/app-debug.apk` (161 MB,
  2026-06-10 19:56:48). `AndroidManifest.xml` includes
  `io.flutter.embedding.android.EnableImpeller=true`, and `MainActivity.kt`
  sets `preferredDisplayModeId` to the highest refresh mode matching the current
  physical resolution when the activity starts or regains focus.
- 2026-06-10: `cd node && nix develop --command dart test test/agent
  test/persistence test/daemon_sync_pi_only_test.dart
  test/normalize_hub_url_test.dart` passed 38 tests, covering strict JSON line
  splitting, session pagination/source indexes, malformed session lines,
  live tool-call ids, long payload preservation, UTF-8 tail handling, byte-offset
  duplicate handling, persisted protocol replay, and `hasMore` pagination.
- 2026-06-10: `cd client && nix develop --command flutter test
  test/screens/task_detail_screen_test.dart` passed 6 widget tests, including a
  repeated streaming Markdown-delta proxy that keeps `PiMarkdown.debugCacheSize`
  at 0 during 16 live deltas and allows exactly one cached Markdown render after
  task completion.
- 2026-06-10: `cd client && nix develop --command flutter test
  test/screens/dashboard_screen_test.dart` passed 3 widget tests, including the
  Dashboard long-press action sheet path and an explicit assertion that task
  cards no longer use `Dismissible` swipe-delete.
- 2026-06-10: `cd client && nix develop --command flutter test
  test/services/websocket_service_url_test.dart` passed 6 tests, including real
  local WebSocket coverage for missed-pong half-open disconnect and pong-driven
  healthy connection keep-alive.
- 2026-06-10: `cd client && nix develop --command flutter analyze` reported no
  issues, and `cd client && nix develop --command flutter test` passed 59 tests.
- 2026-06-10: Added `just client-profile <device>
  [trace=build/mobilepi-profile-trace.binpb]`, which runs
  `flutter run --profile` with `--trace-to-file`, `--endless-trace-buffer`, and
  `--trace-systrace`. `nix develop --command just --list` verifies the recipe is
  available in the project dev environment.
- 2026-06-10: Added `integration_test/mobilepi_performance_test.dart` plus
  `test_driver/perf_driver.dart`. The probe uses
  `IntegrationTestWidgetsFlutterBinding.traceAction` to record
  `streaming_detail_timeline`, `dashboard_scroll_timeline`, and
  `session_cache_hydration_timeline`. These cover 48 Markdown-heavy live deltas
  on a real `TaskDetailScreen` / `NodeProvider` path, 120-row Dashboard
  scrolling, and 120-snapshot SessionCache hydration. The driver writes timeline
  and summary files for each report key through `integrationDriver`.
- 2026-06-10: Added `just client-profile-test <device>` for
  `flutter drive --profile --driver=test_driver/perf_driver.dart
  --target=integration_test/mobilepi_performance_test.dart`. `flutter analyze`
  passed and regular `flutter test` passed 59 tests after adding the probe.
  Running `flutter test integration_test/mobilepi_performance_test.dart` in the
  current desktop environment did not execute because no supported device is
  connected; this remains a device/profile evidence gap, not a compile error.
- 2026-06-10: Extended the performance probe from one timeline to the three
  acceptance scenarios listed in the remaining gaps. `flutter analyze` still
  reports no issues and regular `flutter test` still passes 59 tests.
- 2026-06-10: Added `tool/check_profile_summaries.dart` plus
  `just client-profile-check [build_dir] [budget_ms]`. The checker looks for
  the three timeline summary files, extracts build/raster average and 90th/99th
  percentile metrics, and fails when any metric exceeds the 8.3 ms default
  frame budget. `dart analyze tool/check_profile_summaries.dart` passed, and a
  synthetic three-summary run passed against the 8.3 ms budget.
- 2026-06-10: `cd client && nix develop --command flutter build apk --profile`
  succeeded and produced `client/build/app/outputs/flutter-apk/app-profile.apk`
  (80.9 MB from Flutter output, 80,908,459 bytes on disk, 2026-06-10 20:04:10).
  This verifies the Android profile build path used by the performance probe;
  it still does not replace running the probe on a connected device.
- 2026-06-10: `MainActivity.kt` now emits `MobilePiRefresh` logcat entries for
  `refresh_mode_selected`, `refresh_mode_already_selected`, and unsupported SDK
  skips, including mode ids, refresh rates, and physical resolution. Added
  `just android-refresh-log [device]` to fetch those entries with adb.
  `nix develop --command just --list` shows the recipe, and
  `cd client && nix develop --command flutter build apk --debug` still succeeds
  after adding the logging hook.
- 2026-06-10: Added `tool/check_android_refresh_log.dart`,
  `just android-refresh-check <log_file> [min_hz]`, and
  `just android-refresh-verify [device] [min_hz]`. The checker parses
  `MobilePiRefresh` logcat lines, requires a selected/already-selected refresh
  event, and fails when the best selected refresh is below the 90 Hz default
  threshold. `dart format`, `dart analyze tool/check_android_refresh_log.dart`,
  `nix develop --command just --list`, and synthetic 120 Hz pass / 60 Hz fail
  samples all succeeded.
- 2026-06-10: Added `test/tool/performance_verification_tools_test.dart` to
  exercise the profile-summary and Android-refresh checker command-line entry
  points. The tests cover all three required profile summary keys, over-budget
  failure reporting, stdin parsing of the first `MobilePiRefresh` line, and
  below-threshold refresh failure. `cd client && nix develop --command flutter
  test test/tool/performance_verification_tools_test.dart` passed 4 tests;
  `cd client && nix develop --command flutter analyze` passed; and the full
  `cd client && nix develop --command flutter test` suite passed 63 tests.
- 2026-06-10: Hardened `tool/check_profile_summaries.dart` so a profile summary
  must include positive `frame_count` and `frame_rasterizer_count` samples
  before frame-budget metrics are accepted. This prevents empty/too-short
  timeline captures from being treated as performance evidence. Extended
  `test/tool/performance_verification_tools_test.dart` with the empty-sample
  failure case. `cd client && nix develop --command flutter test
  test/tool/performance_verification_tools_test.dart` passed 5 tests;
  `cd client && nix develop --command dart analyze tool/check_profile_summaries.dart
  tool/check_android_refresh_log.dart` passed; `cd client && nix develop
  --command flutter analyze` passed; and the full `cd client && nix develop
  --command flutter test` suite passed 64 tests.
- 2026-06-10: Added `just client-device-acceptance <device> [budget_ms]
  [min_hz]` to run the remaining device evidence path as one command: clear
  `MobilePiRefresh` logcat, run the Flutter profile integration probe, check
  the generated timeline summaries, then verify high-refresh selection logs.
  `nix develop --command just --list` shows the recipe, and
  `nix develop --command just --dry-run client-device-acceptance android-serial
  8.3 90` expands to the expected four commands. This improves evidence
  collection repeatability but still requires a connected Android device for
  real acceptance data.
- 2026-06-10: Added `tool/check_refactor_audit.dart` plus
  `just refactor-audit-check` so the audit matrix must include every
  `output.md` bucket (`P-1` through `P-6`, `U-1` through `U-3`, `D-1` through
  `D-6`, and `Network`) and must keep Remaining Completion Gaps when any row is
  partial. `nix develop --command just refactor-audit-check` passes on the
  current audit with 16 covered areas (13 proven, 3 partial). Extended
  `test/tool/performance_verification_tools_test.dart` with pass/missing-row
  coverage for the audit checker.
- 2026-06-10: Re-ran device discovery: `cd client && nix develop --command
  flutter devices` still reports only macOS desktop, and `cd client && nix
  develop --command flutter emulators` reports no emulator sources. This keeps
  the Android/profile evidence gap open.
- 2026-06-10: The full `cd client && nix develop --command flutter test` suite
  initially exposed a race in the healthy-connection WebSocket test server:
  a late ping could be answered after the test socket closed, throwing
  `StreamSink is closed`. The test server now checks `WebSocket.open` and
  tolerates `StateError` during teardown. Targeted
  `test/services/websocket_service_url_test.dart` passed 6 tests,
  `test/tool/performance_verification_tools_test.dart` passed 7 tests,
  `cd client && nix develop --command dart analyze tool/check_refactor_audit.dart
  tool/check_profile_summaries.dart tool/check_android_refresh_log.dart`
  passed, `cd client && nix develop --command flutter analyze` passed, and the
  full `cd client && nix develop --command flutter test` suite passed 66 tests.
- 2026-06-10: Improved U-3 mobile ergonomics evidence by expanding the task
  detail log drawer handle hit area from 24dp to 44dp while keeping the visual
  handle compact, and added a widget test that asserts the bottom log handle
  and send button both keep at least 44dp touch targets. `cd client && nix
  develop --command flutter test test/screens/task_detail_screen_test.dart`
  passed 7 tests, `cd client && nix develop --command flutter analyze` passed,
  and the full `cd client && nix develop --command flutter test` suite passed
  67 tests.
- 2026-06-10: Strengthened Network lifecycle evidence by adding a test-only
  `MobilePiApp(provider: ...)` injection point and
  `test/app_lifecycle_test.dart`, which sends `AppLifecycleState.paused` and
  `AppLifecycleState.resumed` through Flutter's binding and asserts only
  `resumed` triggers the provider's WebSocket `forceReconnect()` path.
  `cd client && nix develop --command flutter test test/app_lifecycle_test.dart`
  passed, `cd client && nix develop --command flutter analyze` passed, and the
  full `cd client && nix develop --command flutter test` suite passed 68 tests.
- 2026-06-10: Added `test/android/android_wiring_test.dart` to guard P-6's
  Android platform wiring without a device. It verifies
  `AndroidManifest.xml` keeps `io.flutter.embedding.android.EnableImpeller=true`
  and `MainActivity.kt` still reapplies the highest matching refresh mode on
  create/focus, writes `preferredDisplayModeId`, and emits the
  `MobilePiRefresh` selected/already-selected/unsupported-sdk log events used
  by the device acceptance checker. `cd client && nix develop --command flutter
  test test/android/android_wiring_test.dart` passed 2 tests, `cd client && nix
  develop --command flutter analyze` passed, and the full `cd client && nix
  develop --command flutter test` suite passed 70 tests.
- 2026-06-10: Added `just local-acceptance` to run all non-device acceptance
  checks in one command: shared/hub/node analysis, hub tests, automated node
  tests, client analysis/tests, debug/profile APK builds, and the refactor audit
  checker. The node step intentionally excludes `node/test/e2e/e2e_test.dart`
  because it is a manual live-daemon script, not a deterministic unit/integration
  test. `nix develop --command just --dry-run local-acceptance` expands to the
  expected command list, and `nix develop --command just local-acceptance`
  passed end-to-end: shared/hub/node/client analyzers clean, hub tests passed 6,
  automated node tests passed 38, client tests passed 70, debug/profile APKs
  built, and `refactor-audit-check` passed with 16 covered areas (13 proven,
  3 partial).
- 2026-06-10: Hardened `just client-device-acceptance` as an evidence-producing
  command. It now creates `client/build`, runs the profile probe with
  `FLUTTER_TEST_OUTPUTS_DIR=build`, validates the generated timeline summaries,
  and saves raw `MobilePiRefresh` logcat output to
  `client/build/android-refresh.log` via `tee` while also piping it into the
  high-refresh checker. Added a static recipe regression test in
  `test/tool/performance_verification_tools_test.dart` so these artifact paths
  do not drift. `cd client && nix develop --command flutter test
  test/tool/performance_verification_tools_test.dart` passed 8 tests,
  `nix develop --command just --dry-run client-device-acceptance android-serial
  8.3 90` shows the expected artifact-producing commands, and the full
  `cd client && nix develop --command flutter test` suite passed 71 tests.
- 2026-06-10: Added `just client-device-artifacts-check` so saved device
  acceptance artifacts can be rechecked without re-running the device probe:
  timeline summaries under `client/build` are validated against the frame
  budget, and `client/build/android-refresh.log` is validated against the
  high-refresh threshold. Extended
  `test/tool/performance_verification_tools_test.dart` with static recipe
  coverage so this offline evidence path remains wired. `cd client && nix
  develop --command flutter test test/tool/performance_verification_tools_test.dart`
  passed 9 tests, `nix develop --command just --dry-run
  client-device-artifacts-check build build/android-refresh.log 8.3 90` expands
  to the expected two artifact checker commands, and `nix develop --command
  just refactor-audit-check` still passes with 16 covered areas (13 proven,
  3 partial).
- 2026-06-10: Added `integration_test/mobilepi_interaction_test.dart` plus
  `just client-interaction-test <device>` and wired it into
  `just client-device-acceptance`. The probe runs the mobile dashboard decision
  actions, no-swipe-delete/long-press action sheet, panic confirmation, task
  detail log drawer, 44dp log/send targets, and left-edge back gesture in a
  device/profile `flutter drive` path. `cd client && nix develop --command
  flutter analyze integration_test/mobilepi_interaction_test.dart
  test/tool/performance_verification_tools_test.dart` passed, `cd client && nix
  develop --command flutter test test/tool/performance_verification_tools_test.dart`
  passed 10 tests, and `nix develop --command just --dry-run
  client-device-acceptance android-serial 8.3 90` now includes the interaction
  probe after the performance summary check. Local `flutter test
  integration_test/mobilepi_interaction_test.dart` could not run because
  Flutter still sees only the unsupported macOS desktop device and no Android
  device/emulator.
- 2026-06-10: Added `MobilePiLifecycle` foreground-resume log markers in
  `MobilePiApp` and `NodeProvider.onAppResumed()`, plus
  `tool/check_android_lifecycle_log.dart`, `just android-lifecycle-verify`, and
  `just android-lifecycle-check`. The checker requires both an `app_resumed`
  lifecycle marker and `action=force_reconnect`, and fails when the resume path
  logs `skip_missing_tenant_key`, so device evidence cannot pass when foreground
  reconnect was skipped. `just client-device-acceptance` now backgrounds and
  foregrounds `com.example.mobilepi_client`, saves `client/build/android-lifecycle.log`,
  and runs the lifecycle checker; `just client-device-artifacts-check` also
  rechecks the saved lifecycle log. `cd client && nix develop --command flutter
  test test/app_lifecycle_test.dart` passed, `cd client && nix develop --command
  flutter test test/tool/performance_verification_tools_test.dart` passed 13
  tests, `dart analyze tool/check_android_lifecycle_log.dart` passed, targeted
  Flutter analysis passed for `lib/app.dart`, `lib/providers/node_provider.dart`,
  and the tool tests, and both lifecycle dry-runs expand to the expected adb and
  checker commands. Real Android execution evidence is still pending.
- 2026-06-10: Tightened the Android lifecycle verification path by replacing
  the previous launcher `monkey` foreground step with deterministic
  `adb shell am start -n com.example.mobilepi_client/.MainActivity`, matching
  `android/app/build.gradle.kts` and `AndroidManifest.xml`. Added static
  coverage in `test/android/android_wiring_test.dart` to keep the Justfile
  lifecycle recipes aligned with the declared package/activity and to prevent
  regression back to `monkey`. `cd client && nix develop --command flutter test
  test/android/android_wiring_test.dart` passed 3 tests, full `cd client && nix
  develop --command flutter test` passed 77 tests, `nix develop --command just
  --dry-run client-device-acceptance android-serial 8.3 90` and `nix develop
  --command just --dry-run android-lifecycle-verify android-serial` both show
  the deterministic Activity start, and `nix develop --command just
  refactor-audit-check` still passes with 16 covered areas (13 proven,
  3 partial).
- 2026-06-10: Tightened `tool/check_refactor_audit.dart` so partial
  device-dependent rows must keep their executable evidence contracts visible:
  P-6 requires the device acceptance/high-refresh commands, refresh log path,
  and refresh checker; U-3 requires the interaction device probe; Network
  requires the lifecycle verifier, lifecycle log path, and lifecycle checker.
  Any partial device row also requires `client-device-artifacts-check`, so
  saved device evidence remains replayable. Added a regression test that fails
  a synthetic partial Network audit when these markers are omitted. `cd client
  && nix develop --command flutter test
  test/tool/performance_verification_tools_test.dart` passed 14 tests, and
  `nix develop --command just refactor-audit-check` passes the real audit with
  16 covered areas (13 proven, 3 partial).
- 2026-06-10: Added `tool/check_android_device.dart` plus
  `just android-device-check <device>` and wired it as the first executable
  step in `just client-device-acceptance`. The checker parses `adb devices`,
  passes only when the requested serial is in `device` state, and fails clearly
  for missing/offline devices before any profile drive, logcat, or lifecycle
  work begins. `tool/check_refactor_audit.dart` now also requires this checker
  marker for partial P-6 device evidence. `cd client && nix develop --command
  dart analyze tool/check_android_device.dart tool/check_refactor_audit.dart`
  passed, `cd client && nix develop --command flutter test
  test/tool/performance_verification_tools_test.dart` passed 17 tests,
  `cd client && nix develop --command flutter test` passed 81 tests, and
  `nix develop --command just refactor-audit-check` passes with 16 covered areas
  (13 proven, 3 partial).
- 2026-06-10: Made the device profile and interaction probe outputs replayable
  by saving `flutter drive` stdout/stderr to
  `client/build/mobilepi-performance-drive.log` and
  `client/build/mobilepi-interaction-drive.log` with `bash -o pipefail`, then
  checking both logs through `tool/check_flutter_drive_log.dart`. The saved
  artifacts checker now validates profile summaries, refresh log, lifecycle
  log, and both drive logs. `tool/check_refactor_audit.dart` also requires
  these drive log markers for the partial P-6/U-3 evidence contracts.
  `cd client && nix develop --command flutter test
  test/tool/performance_verification_tools_test.dart` passed 19 tests, and
  dry-runs for `client-device-acceptance` plus `client-device-artifacts-check`
  show the expected `tee` and log-checker commands.
- 2026-06-10: Added strict completion mode to `tool/check_refactor_audit.dart`
  and exposed it as `just refactor-completion-check`. Normal
  `refactor-audit-check` still passes while partial rows remain, but
  completion mode fails unless all 16 areas are proven. Synthetic tests cover
  both all-proven success and partial failure. On the current real audit,
  `nix develop --command just refactor-completion-check` correctly fails with
  `completion requires no partial areas; still partial: P-6, U-3, Network`,
  which is executable evidence that the active goal must not yet be marked
  complete. `cd client && nix develop --command flutter test
  test/tool/performance_verification_tools_test.dart` passed 21 tests,
  `dart analyze tool/check_refactor_audit.dart` passed, and
  `nix develop --command just refactor-audit-check` still passes with 16 covered
  areas (13 proven, 3 partial).
- 2026-06-10: Strengthened `tool/check_flutter_drive_log.dart` so saved
  `flutter drive` logs must include the expected integration scenario names,
  not only a generic success marker. `just client-device-acceptance` and
  `just client-device-artifacts-check` now require the three performance probes
  (`profile streaming task detail timeline`, `profile dashboard scrolling
  timeline`, `profile session cache hydration timeline`) and the two mobile
  interaction probes (`mobile dashboard actions run on-device gesture paths`,
  `task detail gestures keep mobile conversation controls usable`). `cd client
  && nix develop --command flutter test
  test/tool/performance_verification_tools_test.dart` passed 22 tests, full
  `cd client && nix develop --command flutter test` passed 86 tests,
  `cd client && nix develop --command dart analyze
  tool/check_flutter_drive_log.dart tool/check_refactor_audit.dart` passed, and
  dry-runs for both device acceptance and saved-artifact checks show the marker
  checks wired into the executable path. Real Android execution evidence is
  still pending for P-6, U-3, and Network.
- 2026-06-10: Added `tool/check_device_acceptance_manifest.dart` and wired
  `just client-device-acceptance` to write
  `client/build/mobilepi-device-acceptance.json` after the performance,
  interaction, refresh, and lifecycle artifacts are produced. The saved-artifact
  replay command now requires the target `<device>` and validates that the
  manifest's device, budget, refresh threshold, artifact paths, file sizes, and
  modification times still match the current files, preventing mixed or stale
  logs from passing offline review. `tool/check_refactor_audit.dart` now keeps
  the manifest path and checker in the partial P-6 evidence contract. `cd
  client && nix develop --command flutter test
  test/tool/performance_verification_tools_test.dart` passed 24 tests, `cd
  client && nix develop --command dart analyze
  tool/check_device_acceptance_manifest.dart tool/check_refactor_audit.dart`
  passed, and dry-runs for `client-device-acceptance` plus
  `client-device-artifacts-check` show the manifest write/check commands.
- 2026-06-10: Tightened `tool/check_refactor_audit.dart --complete` so the goal
  cannot be marked complete by only changing matrix statuses to Proven.
  Completion mode now also fails if `Remaining Completion Gaps` still contains
  bullets, and it requires the P-6/U-3/Network device evidence markers even
  when those rows are marked Proven. Synthetic tests cover all-proven success,
  remaining-gap failure, missing-device-marker failure, and partial-row failure.
  `cd client && nix develop --command flutter test
  test/tool/performance_verification_tools_test.dart` passed 26 tests, and
  `cd client && nix develop --command dart analyze tool/check_refactor_audit.dart`
  passed.
- 2026-06-10: Tightened normal `tool/check_refactor_audit.dart` checks so every
  partial matrix row must be explicitly named in `Remaining Completion Gaps`.
  The real audit now lists separate P-6, U-3, and Network bullets instead of a
  generic device-verification note, so the open work remains requirement-scoped
  and cannot hide a partial area behind broad wording. Added a regression test
  that fails when a partial U-3 row is not mentioned in the gaps section.
- 2026-06-10: Re-ran the full non-device acceptance chain on the current
  worktree with `nix develop --command just local-acceptance`. Shared, Hub,
  Node, and Client analyzers were clean; Hub tests passed 6; automated Node
  tests passed 38; Client tests passed 91; debug APK built successfully; profile
  APK built successfully at `client/build/app/outputs/flutter-apk/app-profile.apk`
  (103.7 MB from Flutter output); and `refactor-audit-check` passed with 16
  covered areas (13 proven, 3 partial). This refreshes the local evidence after
  the stricter completion/audit gates, but it still does not replace the real
  Android/profile evidence needed for P-6, U-3, and Network.
- 2026-06-10: Extended `tool/check_device_acceptance_manifest.dart` so the
  device acceptance manifest also records and verifies the three profile
  timeline summary files:
  `streaming_detail_timeline.timeline_summary.json`,
  `dashboard_scroll_timeline.timeline_summary.json`, and
  `session_cache_hydration_timeline.timeline_summary.json`. This closes the
  remaining stale-artifact loophole where drive/log files were locked but frame
  budget summaries could be replaced under the same build directory before
  offline replay. `tool/check_refactor_audit.dart` now requires these summary
  markers in the P-6 device evidence contract, and the tool tests include a
  regression where changing a summary after manifest creation fails replay.
- 2026-06-10: Added per-file `contentCrc32` checks to
  `tool/check_device_acceptance_manifest.dart`, so saved device artifacts are
  verified by path, type, size, modified time, and content fingerprint. This
  catches same-size artifact swaps even when the file timestamp is restored.
  Added a regression that rewrites `mobilepi-performance-drive.log` with the
  same byte count and original mtime; manifest replay still fails on
  `performanceLog contentCrc32`. `cd client && nix develop --command flutter
  test test/tool/performance_verification_tools_test.dart` passed 29 tests, and
  `cd client && nix develop --command dart analyze
  tool/check_device_acceptance_manifest.dart` passed.
- 2026-06-10: Bumped the device acceptance manifest schema to v2 to make the
  `contentCrc32` requirement explicit. Old schema v1 manifests are now rejected
  instead of being treated as equivalent to content-fingerprinted evidence.
  Added a regression that rewrites a generated manifest back to `schema: 1` and
  verifies replay fails with `schema expected "2" but found "1"`. `cd client &&
  nix develop --command flutter test test/tool/performance_verification_tools_test.dart`
  passed 30 tests, and `cd client && nix develop --command dart analyze
  tool/check_device_acceptance_manifest.dart` passed.
- 2026-06-10: Extended the device acceptance manifest to bind evidence to the
  actual profile Android build by recording
  `build/app/outputs/flutter-apk/app-profile.apk` as the `profileApk` artifact,
  including size, modified time, and `contentCrc32`. The manifest schema is now
  v3, and schema v2 manifests are rejected because they do not prove the APK
  artifact was part of the evidence set. Added a regression that modifies the
  profile APK after manifest creation and verifies replay fails on `profileApk`.
- 2026-06-10: Updated `just client-device-acceptance` to run
  `flutter build apk --profile` after the Android device readiness check and
  before the profile `flutter drive` probes. This makes the `profileApk`
  manifest entry a fresh artifact from the same acceptance command instead of a
  stale build leftover. The static Justfile regression now requires the profile
  build step in the device acceptance recipe.
- 2026-06-10: Re-verified the latest audit/tooling state after adding the
  device profile APK build step. `cd client && nix develop --command flutter
  test` passed 95 tests, `nix develop --command just refactor-audit-check`
  passed with 16 covered areas (13 proven, 3 partial), and `git diff --check`
  passed for the audit/tooling changes. `nix develop --command just
  refactor-completion-check` still fails by design because P-6, U-3, and
  Network remain partial until real Android/profile artifacts are captured and
  the Remaining Completion Gaps section is emptied.
- 2026-06-10: Tightened Android lifecycle evidence so Network device logs must
  prove an actual background/foreground transition, not just a standalone
  resume marker. `MobilePiApp` now logs `MobilePiLifecycle event=app_paused`;
  `tool/check_android_lifecycle_log.dart` requires `app_paused` before
  `app_resumed action=force_reconnect` and fails if reconnect is skipped after
  pause; `just android-lifecycle-verify` and the lifecycle segment of
  `client-device-acceptance` explicitly run app start -> HOME -> app start
  before reading logcat. `cd client && nix develop --command flutter test
  test/app_lifecycle_test.dart test/tool/performance_verification_tools_test.dart`
  passed 33 tests, and targeted Dart analysis for the app lifecycle/tool/test
  files passed.
- 2026-06-10: Tightened P-6 profile summary verification so incomplete timeline
  summaries cannot pass as frame-budget evidence. `tool/check_profile_summaries.dart`
  now requires all six frame timing metrics for every required scenario:
  average/p90/p99 build time and average/p90/p99 rasterizer time. Added a
  regression where `session_cache_hydration_timeline` omits the p99 rasterizer
  metric and the checker fails with `missing frame timing metric(s)`. `cd
  client && nix develop --command flutter test
  test/tool/performance_verification_tools_test.dart` passed 33 tests, and
  targeted Dart analysis for the profile checker and tool tests passed.
- 2026-06-10: Tightened saved `flutter drive` log verification for both P-6
  performance probes and U-3 interaction probes. `tool/check_flutter_drive_log.dart`
  now requires an explicit final `All tests passed` marker instead of accepting
  progress lines with positive test counts, so interrupted or truncated drive
  logs cannot satisfy device acceptance. Added a regression where a log contains
  only `00:.. +N` progress lines and fails with `no final success marker`.
  `cd client && nix develop --command flutter test
  test/tool/performance_verification_tools_test.dart` passed 34 tests, and
  targeted Dart analysis for the drive-log checker and tool tests passed.
- 2026-06-10: Tightened Android high-refresh log verification so P-6 device
  evidence must include complete selection metadata, not only a refresh-rate
  number. `tool/check_android_refresh_log.dart` now rejects selection evidence
  missing `modeId`, positive `refreshRate`, positive `width`, or positive
  `height`, matching the `MobilePiRefresh` fields emitted by `MainActivity`.
  Added a regression where a 120 Hz selection omits width/height and fails with
  `Refresh selection evidence is incomplete`. `cd client && nix develop
  --command flutter test test/tool/performance_verification_tools_test.dart`
  passed 35 tests, and targeted Dart analysis for the refresh checker and tool
  tests passed.
- 2026-06-12: Created and started an Android emulator for device-path testing:
  installed SDK `emulator` plus
  `system-images;android-36;google_apis;arm64-v8a`, created AVD
  `MobilePi_API_36`, and verified Flutter sees
  `emulator-5554` as `sdk gphone64 arm64 (Android 16 API 36)`. The project
  device checker passed with `nix develop --command just android-device-check
  emulator-5554`.
- 2026-06-12: Ran the split profile drive on the emulator with
  `nix develop --command just client-profile-test emulator-5554
  build/mobilepi-emulator-performance-drive.log`. All three drive scenarios
  reported `All tests passed`, and the driver wrote
  `streaming_detail_timeline`, `dashboard_scroll_timeline`, and
  `session_cache_hydration_timeline` timeline plus summary files under
  `client/build`. `tool/check_flutter_drive_log.dart` passed for the emulator
  performance log. `tool/check_profile_summaries.dart build 8.3` failed on the
  emulator with over-budget raster/build metrics, so this evidence proves the
  profile-drive artifact path works on Android but does not prove P-6's real
  high-refresh 8.3 ms acceptance target.
- 2026-06-12: Ran the mobile gesture drive on the emulator with
  `nix develop --command just client-interaction-test emulator-5554
  build/mobilepi-emulator-interaction-drive.log`. The first run exposed a test
  contract mismatch: `waitingDecision` rows expose inline `停止`, while the
  long-press `紧急停止` sheet action is only for `running` tasks. Updated
  `integration_test/mobilepi_interaction_test.dart` to verify the inline
  waiting action first, then emit a higher-sequence `running` status before
  checking the long-press panic sheet. `flutter analyze
  integration_test/mobilepi_interaction_test.dart`,
  `flutter test test/screens/dashboard_screen_test.dart`, the rerun
  interaction drive, and `tool/check_flutter_drive_log.dart` all passed.
- 2026-06-12: Captured emulator refresh and lifecycle logs. The emulator
  `MobilePiRefresh` log records complete mode metadata at 60 Hz
  (`modeId=1`, `refreshRate=60.000004`, `width=1080`, `height=2400`), and
  `tool/check_android_refresh_log.dart build/android-emulator-refresh.log 60`
  passed. A normal profile APK built with
  `--dart-define=MOBILE_PI_TENANT_KEY=tenant-a` passed the foreground lifecycle
  verifier after start -> HOME -> start:
  `app_paused`, `app_resumed`, and
  `app_resumed action=force_reconnect` were recorded in
  `build/android-emulator-lifecycle.log`. This proves the Android lifecycle
  evidence path on an emulator, but the real-device Network gap remains open
  until the same log is captured from a physical Android device.
