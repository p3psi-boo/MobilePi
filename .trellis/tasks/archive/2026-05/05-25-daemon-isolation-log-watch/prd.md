# PRD: Daemon Resource Isolation & Log Watching

## 1. Background & Goals
Currently, the MobilePi Daemon uses a 1.2-second timer to poll log files, causing unnecessary I/O and CPU overhead while idling. It also launches the `pi` Agent as a direct local subprocess with full user permissions and no resource boundaries.

The goals of this task are:
1. **Low-Latency, Zero-Idle Log Watching**: Upgrade the polling timer to Dart's OS-native `File.watch()` to achieve sub-millisecond real-time updates and eliminate idle polling CPU/Disk I/O.
2. **Process sandboxing & Resource quotas**: Wrap subprocess launching with system wrappers (`systemd-run` for Linux, `sandbox-exec` for macOS) to enforce CPU/Memory limits and block unauthorized writes to system directories.

## 2. Requirements

### 2.1 File Watching (Log Watch)
- Refactor the session watch mechanism in `node/lib/daemon.dart`.
- Instead of using a periodic `Timer`, use `file.watch(events: FileSystemEvent.modify)` to watch the session JSONL file.
- Support robust fallback if the file doesn't exist when the watch is initialized (e.g. create the empty file first).
- Properly manage and cancel the stream subscriptions to prevent memory/descriptor leaks.

### 2.2 Subprocess Sandboxing & Quotas
- Retrieve configuration from environment variables:
  - `MOBILE_PI_SANDBOX_MODE`: `'systemd'`, `'macos'`, or `'none'`.
  - `MOBILE_PI_CPU_LIMIT`: e.g. `'50%'` (CPU quota limit).
  - `MOBILE_PI_MEM_LIMIT`: e.g. `'2G'` (Memory limit).
- Implement macOS `sandbox-exec` wrapper:
  - If mode is `'macos'`, run the executable inside a sandbox profile that allows default actions but denies writes to `/System`, `/usr`, and `/Library`.
- Implement Linux `systemd-run` wrapper:
  - If mode is `'systemd'`, run in user scope with `-p CPUQuota=<limit>` and `-p MemoryMax=<limit>`.
- Keep direct local subprocess execution if mode is `'none'` or unsupported.
