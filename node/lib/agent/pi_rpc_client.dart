import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';

class PiRpcClient {
  PiRpcClient({
    this.executable = 'pi',
    this.args = const <String>['--mode', 'rpc', '--no-session'],
    this.workingDirectory,
    Map<String, String>? environment,
    this.sandboxMode,
    this.cpuLimit,
    this.memLimit,
  }) : environment = environment == null
           ? null
           : Map<String, String>.unmodifiable(environment);

  final String executable;
  final List<String> args;
  final String? workingDirectory;
  final Map<String, String>? environment;
  final String? sandboxMode;
  final String? cpuLimit;
  final String? memLimit;

  final Logger _logger = Logger('PiRpcClient');
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  Future<int>? _exitCode;
  var _requestId = 0;
  var _stderr = '';

  Stream<Map<String, dynamic>> get events => _events.stream;
  bool get isStarted => _process != null;
  String get stderr => _stderr;

  Future<void> start() async {
    if (_process != null) return;

    var exec = executable;
    var execArgs = List<String>.from(args);

    final mode =
        (sandboxMode ?? Platform.environment['MOBILE_PI_SANDBOX_MODE'])
            ?.trim()
            .toLowerCase() ??
        'none';
    final cpu =
        (cpuLimit ?? Platform.environment['MOBILE_PI_CPU_LIMIT'])?.trim() ??
        '50%';
    final mem =
        (memLimit ?? Platform.environment['MOBILE_PI_MEM_LIMIT'])?.trim() ??
        '2G';

    if (mode == 'systemd') {
      if (Platform.isLinux) {
        _logger.info(
          'event=pi_rpc.sandbox_enabled mode=systemd cpu=$cpu mem=$mem',
        );
        execArgs = [
          '--user',
          '--scope',
          '-p',
          'CPUQuota=$cpu',
          '-p',
          'MemoryMax=$mem',
          exec,
          ...execArgs,
        ];
        exec = 'systemd-run';
      } else {
        _logger.warning(
          'event=pi_rpc.sandbox_failed reason=systemd_unsupported_on_platform platform=${Platform.operatingSystem}',
        );
      }
    } else if (mode == 'macos') {
      if (Platform.isMacOS) {
        _logger.info('event=pi_rpc.sandbox_enabled mode=macos');
        // A standard macos sandbox profile that restricts system dir writes
        const profile =
            '(version 1)\n'
            '(allow default)\n'
            '(deny file-write* (subpath "/System"))\n'
            '(deny file-write* (subpath "/usr"))\n'
            '(deny file-write* (subpath "/Library"))';
        execArgs = ['-p', profile, exec, ...execArgs];
        exec = 'sandbox-exec';
      } else {
        _logger.warning(
          'event=pi_rpc.sandbox_failed reason=macos_sandbox_unsupported_on_platform platform=${Platform.operatingSystem}',
        );
      }
    }

    final process = await Process.start(
      exec,
      execArgs,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    _process = process;
    _exitCode = process.exitCode;
    _logger.info(
      'event=pi_rpc.start ${logFields({'executable': exec, 'args': execArgs.join(' '), if (workingDirectory != null) 'cwd': workingDirectory, 'pid': process.pid})}',
    );

    _stderrSub = process.stderr.transform(utf8.decoder).listen((chunk) {
      _stderr += chunk;
      final visibleChunk = filterPiStderrForLog(chunk);
      if (visibleChunk.trim().isNotEmpty) {
        _logger.fine('pi stderr chunk: ${jsonEncode(visibleChunk)}');
      }
    });

    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const StrictJsonLineSplitter())
        .listen(
          _handleLine,
          onError: (Object error, StackTrace stackTrace) {
            _logger.warning('event=pi_rpc.stdout_error', error, stackTrace);
            _failPending(StateError('Pi stdout error: $error'));
          },
          onDone: () {
            _logger.warning('event=pi_rpc.stdout_done');
            _failPending(StateError('Pi RPC process exited'));
          },
        );

    unawaited(
      _exitCode!.then((code) {
        _logger.info(
          'event=pi_rpc.exit ${logFields({'pid': process.pid, 'exitCode': code})}',
        );
        _failPending(StateError('Pi RPC process exited with code $code'));
      }),
    );

    await Future<void>.delayed(const Duration(milliseconds: 80));
  }

  Future<void> stop() async {
    final process = _process;
    if (process == null) return;

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _process = null;
    _failPending(StateError('Pi RPC client stopped'));

    _logger.info('event=pi_rpc.stop ${logField('pid', process.pid)}');
    process.kill(ProcessSignal.sigterm);
    try {
      await (_exitCode ?? process.exitCode).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
  }

  Future<Map<String, dynamic>> send(Map<String, dynamic> command) async {
    final process = _process;
    if (process == null) {
      throw StateError('Pi RPC client is not started');
    }

    final id = 'mobilepi-${++_requestId}';
    final request = <String, dynamic>{'id': id, ...command};
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    process.stdin.write('${jsonEncode(request)}\n');
    await process.stdin.flush();
    _logger.fine(
      'event=pi_rpc.send ${logFields({'requestId': id, 'command': command['type']})}',
    );

    final response = await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        _logger.warning(
          'event=pi_rpc.timeout ${logFields({'requestId': id, 'command': command['type']})}',
        );
        throw TimeoutException('Pi RPC command timed out: ${command['type']}');
      },
    );

    if (response['success'] != true) {
      _logger.warning(
        'event=pi_rpc.command_failed ${logFields({'requestId': id, 'command': response['command'] ?? command['type'], 'error': response['error']})}',
      );
      throw StateError(
        'Pi RPC ${response['command'] ?? command['type']} failed: '
        '${response['error'] ?? 'unknown error'}',
      );
    }
    _logger.fine(
      'event=pi_rpc.response ${logFields({'requestId': id, 'command': response['command'] ?? command['type']})}',
    );
    return response;
  }

  Future<void> prompt(String message) async {
    await send({'type': 'prompt', 'message': message});
  }

  Future<void> steer(String message) async {
    await send({'type': 'steer', 'message': message});
  }

  Future<void> followUp(String message) async {
    await send({'type': 'follow_up', 'message': message});
  }

  Future<void> abort() async {
    await send({'type': 'abort'});
  }

  Future<Map<String, dynamic>> newSession({String? parentSession}) async {
    final command = <String, dynamic>{'type': 'new_session'};
    if (parentSession != null) command['parentSession'] = parentSession;
    return _data(await send(command));
  }

  Future<Map<String, dynamic>> getState() async {
    return _data(await send({'type': 'get_state'}));
  }

  Future<Map<String, dynamic>> setModel(String provider, String modelId) async {
    return _data(
      await send({
        'type': 'set_model',
        'provider': provider,
        'modelId': modelId,
      }),
    );
  }

  Future<Map<String, dynamic>?> cycleModel() async {
    return _nullableData(await send({'type': 'cycle_model'}));
  }

  Future<List<Map<String, dynamic>>> getAvailableModels() async {
    final data = _data(await send({'type': 'get_available_models'}));
    return _mapList(data['models']);
  }

  Future<void> setThinkingLevel(String level) async {
    await send({'type': 'set_thinking_level', 'level': level});
  }

  Future<Map<String, dynamic>?> cycleThinkingLevel() async {
    return _nullableData(await send({'type': 'cycle_thinking_level'}));
  }

  Future<void> setSteeringMode(String mode) async {
    await send({'type': 'set_steering_mode', 'mode': mode});
  }

  Future<void> setFollowUpMode(String mode) async {
    await send({'type': 'set_follow_up_mode', 'mode': mode});
  }

  Future<Map<String, dynamic>> compact({String? customInstructions}) async {
    final command = <String, dynamic>{'type': 'compact'};
    if (customInstructions != null) {
      command['customInstructions'] = customInstructions;
    }
    return _data(await send(command));
  }

  Future<void> setAutoCompaction(bool enabled) async {
    await send({'type': 'set_auto_compaction', 'enabled': enabled});
  }

  Future<void> setAutoRetry(bool enabled) async {
    await send({'type': 'set_auto_retry', 'enabled': enabled});
  }

  Future<void> abortRetry() async {
    await send({'type': 'abort_retry'});
  }

  Future<Map<String, dynamic>> bash(String command) async {
    return _data(await send({'type': 'bash', 'command': command}));
  }

  Future<void> abortBash() async {
    await send({'type': 'abort_bash'});
  }

  Future<Map<String, dynamic>> getSessionStats() async {
    return _data(await send({'type': 'get_session_stats'}));
  }

  Future<Map<String, dynamic>> exportHtml({String? outputPath}) async {
    final command = <String, dynamic>{'type': 'export_html'};
    if (outputPath != null) command['outputPath'] = outputPath;
    return _data(await send(command));
  }

  Future<Map<String, dynamic>> switchSession(String sessionPath) async {
    return _data(
      await send({'type': 'switch_session', 'sessionPath': sessionPath}),
    );
  }

  Future<Map<String, dynamic>> fork(String entryId) async {
    return _data(await send({'type': 'fork', 'entryId': entryId}));
  }

  Future<Map<String, dynamic>> clone() async {
    return _data(await send({'type': 'clone'}));
  }

  Future<List<Map<String, dynamic>>> getForkMessages() async {
    final data = _data(await send({'type': 'get_fork_messages'}));
    return _mapList(data['messages']);
  }

  Future<String?> getLastAssistantText() async {
    final data = _data(await send({'type': 'get_last_assistant_text'}));
    return data['text']?.toString();
  }

  Future<void> setSessionName(String name) async {
    await send({'type': 'set_session_name', 'name': name});
  }

  Future<List<Map<String, dynamic>>> getMessages() async {
    final data = _data(await send({'type': 'get_messages'}));
    return _mapList(data['messages']);
  }

  Future<List<Map<String, dynamic>>> getCommands() async {
    final data = _data(await send({'type': 'get_commands'}));
    return _mapList(data['commands']);
  }

  /// Test hook for the stdout JSONL parser; production input comes from Pi.
  void handleLineForTesting(String line) => _handleLine(line);

  void _handleLine(String line) {
    if (line.isEmpty) return;

    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (e, st) {
      _logger.warning(
        'event=pi_rpc.invalid_line reason=malformed_json ${logField('lineLength', line.length)}',
        e,
        st,
      );
      return;
    }
    if (decoded is! Map) {
      _logger.warning(
        'event=pi_rpc.invalid_line reason=non_object ${logField('lineLength', line.length)}',
      );
      return;
    }
    final message = Map<String, dynamic>.from(decoded);
    if (message['type'] == 'response') {
      final id = message['id']?.toString();
      final completer = id == null ? null : _pending.remove(id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(message);
      } else {
        _logger.warning(
          'event=pi_rpc.unmatched_response ${logFields({'requestId': id, 'command': message['command']})}',
        );
      }
      return;
    }
    _events.add(message);
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  static Map<String, dynamic> _data(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return <String, dynamic>{};
  }

  static Map<String, dynamic>? _nullableData(Map<String, dynamic> response) {
    final data = response['data'];
    if (data == null) return null;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return <String, dynamic>{};
  }

  static List<Map<String, dynamic>> _mapList(Object? value) {
    if (value is! List) return const <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }
}

final _terminalNotificationPattern = RegExp(
  r'\x1B\](?:777;notify;|99;)(?:(?!\x07|\x1B\\)[\s\S])*(?:\x07|\x1B\\)',
);

String filterPiStderrForLog(String chunk) {
  return chunk.replaceAll(_terminalNotificationPattern, '');
}

class StrictJsonLineSplitter extends StreamTransformerBase<String, String> {
  const StrictJsonLineSplitter();

  @override
  Stream<String> bind(Stream<String> stream) {
    late StreamController<String> controller;
    var buffer = '';

    controller = StreamController<String>(
      sync: true,
      onListen: () {
        stream.listen(
          (chunk) {
            buffer += chunk;
            while (true) {
              final index = buffer.indexOf('\n');
              if (index == -1) break;
              controller.add(_stripCr(buffer.substring(0, index)));
              buffer = buffer.substring(index + 1);
            }
          },
          onError: controller.addError,
          onDone: () {
            if (buffer.isNotEmpty) controller.add(_stripCr(buffer));
            controller.close();
          },
          cancelOnError: false,
        );
      },
    );
    return controller.stream;
  }

  static String _stripCr(String line) =>
      line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
}
