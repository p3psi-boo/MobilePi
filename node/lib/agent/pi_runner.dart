import 'dart:async';

import 'package:logging/logging.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';

import 'agent_runner.dart';
import 'pi_rpc_client.dart';

typedef PiRpcClientFactory = PiRpcClient Function();

/// Runs one mobile-visible Pi instance through Pi's RPC protocol.
class PiRunner implements AgentRunner {
  PiRunner({PiRpcClientFactory? clientFactory})
    : _clientFactory = clientFactory ?? (() => PiRpcClient());

  @override
  String get agentType => 'pi';

  final PiRpcClientFactory _clientFactory;
  final Logger _logger = Logger('PiRunner');
  final StreamController<AgentEvent> _eventController =
      StreamController<AgentEvent>.broadcast();

  PiRpcClient? _client;
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  bool _running = false;

  @override
  bool get isRunning => _running;

  @override
  Stream<AgentEvent> get eventStream => _eventController.stream;

  @override
  Future<void> start(String taskId, String prompt, {String? model}) async {
    if (_running) {
      throw StateError('PiRunner is already running');
    }

    final startFields = <String, Object?>{
      'taskId': shortId(taskId),
      'promptLength': prompt.length,
    };
    if (model != null) startFields['model'] = model;
    _logger.info('event=pi_runner.start ${logFields(startFields)}');
    _eventController.add(AgentEvent(state: AgentRunState.starting));

    final client = _clientFactory();
    _client = client;
    try {
      await client.start();
      _eventSub = client.events.listen(
        _handleEvent,
        onError: (Object error) {
          _logger.warning(
            'event=pi_runner.event_stream_error ${logField('taskId', shortId(taskId))}',
            error,
          );
          _eventController.add(
            AgentEvent(state: AgentRunState.error, streamingText: '$error'),
          );
        },
      );

      final selected = _parseModelPath(model);
      if (selected != null) {
        await client.setModel(selected.provider, selected.model);
      }

      _running = true;
      await client.prompt(prompt);
      _logger.info(
        'event=pi_runner.prompt_sent ${logFields({'taskId': shortId(taskId), 'promptLength': prompt.length})}',
      );
    } catch (e, st) {
      _logger.severe(
        'event=pi_runner.start_failed ${logField('taskId', shortId(taskId))}',
        e,
        st,
      );
      _running = false;
      _eventController.add(
        AgentEvent(state: AgentRunState.error, streamingText: '$e'),
      );
      await _cleanup();
    }
  }

  @override
  Future<void> steer(String message) async {
    final client = _client;
    if (client == null || !_running) {
      _logger.warning(
        'event=pi_runner.command_rejected command=steer reason=not_running ${textStats('message', message)}',
      );
      return;
    }
    await client.steer(message);
  }

  @override
  Future<void> prompt(String message) async {
    final client = _client;
    if (client == null || !_running) {
      _logger.warning(
        'event=pi_runner.command_rejected command=prompt reason=not_running ${textStats('message', message)}',
      );
      return;
    }
    await client.prompt(message);
  }

  @override
  Future<void> followUp(String message) async {
    final client = _client;
    if (client == null || !_running) {
      _logger.warning(
        'event=pi_runner.command_rejected command=follow_up reason=not_running ${textStats('message', message)}',
      );
      return;
    }
    await client.followUp(message);
  }

  @override
  Future<void> resumeSession(
    String taskId,
    String sessionPath, {
    String? model,
  }) async {
    if (_running) {
      throw StateError('PiRunner is already running');
    }

    final resumeFields = <String, Object?>{
      'taskId': shortId(taskId),
      'sessionPath': sessionPath,
    };
    if (model != null) resumeFields['model'] = model;
    _logger.info('event=pi_runner.resume ${logFields(resumeFields)}');
    _eventController.add(AgentEvent(state: AgentRunState.starting));

    final client = _clientFactory();
    _client = client;
    try {
      await client.start();
      _eventSub = client.events.listen(
        _handleEvent,
        onError: (Object error) {
          _logger.warning(
            'event=pi_runner.event_stream_error ${logField('taskId', shortId(taskId))}',
            error,
          );
          _eventController.add(
            AgentEvent(state: AgentRunState.error, streamingText: '$error'),
          );
        },
      );

      final selected = _parseModelPath(model);
      if (selected != null) {
        await client.setModel(selected.provider, selected.model);
      }

      await client.switchSession(sessionPath);
      _logger.info(
        'event=pi_runner.session_switched ${logFields({'taskId': shortId(taskId), 'sessionPath': sessionPath})}',
      );

      _running = true;
      _eventController.add(AgentEvent(state: AgentRunState.running));
    } catch (e, st) {
      _logger.severe(
        'event=pi_runner.resume_failed ${logFields({'taskId': shortId(taskId), 'sessionPath': sessionPath})}',
        e,
        st,
      );
      _running = false;
      _eventController.add(
        AgentEvent(state: AgentRunState.error, streamingText: '$e'),
      );
      await _cleanup();
    }
  }

  @override
  Future<void> abort() async {
    final client = _client;
    if (client == null) return;

    try {
      await client.abort();
    } catch (e) {
      _logger.warning('event=pi_runner.abort_failed', e);
    }
    _running = false;
    _eventController.add(AgentEvent(state: AgentRunState.aborted));
    await _cleanup();
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString();

    switch (type) {
      case 'agent_start':
      case 'turn_start':
        _eventController.add(AgentEvent(state: AgentRunState.running));
        break;
      case 'agent_end':
        _running = false;
        _eventController.add(AgentEvent(state: AgentRunState.completed));
        unawaited(_cleanup());
        break;
      case 'message_update':
        final delta = event['assistantMessageEvent'];
        if (delta is! Map) break;
        final deltaType = delta['type']?.toString();

        switch (deltaType) {
          case 'text_delta':
            _eventController.add(
              AgentEvent(streamingText: delta['delta']?.toString()),
            );
            break;
          case 'thinking_start':
            _eventController.add(
              const AgentEvent(streamingText: '<thinking>\n'),
            );
            break;
          case 'thinking_delta':
            _eventController.add(
              AgentEvent(streamingText: delta['delta']?.toString()),
            );
            break;
          case 'thinking_end':
            _eventController.add(
              const AgentEvent(streamingText: '\n</thinking>\n'),
            );
            break;
          case 'toolcall_start':
            final partial = delta['partial'] as Map?;
            final toolCall = partial?['toolCall'] as Map?;
            final name = toolCall?['name']?.toString();
            // Suppress partial toolcall without a name — the reliable name
            // arrives via `tool_execution_start` which is emitted next.
            if (name != null && name.isNotEmpty) {
              _eventController.add(AgentEvent(streamingText: '\n[工具: $name]\n'));
            }
            break;
        }
        break;
      case 'tool_execution_start':
        final toolName = event['toolName']?.toString();
        if (toolName != null && toolName.isNotEmpty) {
          _eventController.add(AgentEvent(streamingText: '\n[工具: $toolName]\n'));
        }
        _eventController.add(
          AgentEvent(
            toolCallId: event['toolCallId']?.toString(),
            toolName: toolName,
          ),
        );
        break;
      case 'tool_execution_update':
        // 实时 partialResult 是累积输出，暂不流式发送，
        // 避免 textBuffer 中堆积重复内容。
        // 最终输出由 tool_execution_end 提供。
        break;
      case 'tool_execution_end':
        _eventController.add(
          AgentEvent(
            toolCallId: event['toolCallId']?.toString(),
            toolResult: _toolResultText(event['result']),
            toolResultIsError: event['isError'] == true,
          ),
        );
        break;
      case 'turn_end':
        final toolResults = event['toolResults'];
        if (toolResults is List && toolResults.isNotEmpty) {
          _eventController.add(
            AgentEvent(progress: toolResults.length / (toolResults.length + 1)),
          );
        }
        break;
      case 'queue_update':
        // Queue depth is internal state; do not stream to the user surface.
        break;
      case 'compaction_start':
        _eventController.add(const AgentEvent(streamingText: '[压缩上下文中]'));
        break;
      case 'compaction_end':
        _eventController.add(const AgentEvent(streamingText: '[上下文压缩完成]'));
        break;
      case 'auto_retry_start':
        _eventController.add(const AgentEvent(streamingText: '[自动重试开始]'));
        break;
      case 'auto_retry_end':
        _eventController.add(const AgentEvent(streamingText: '[自动重试结束]'));
        break;
      case 'extension_error':
        _eventController.add(
          AgentEvent(
            state: AgentRunState.error,
            streamingText: event['error']?.toString() ?? 'Pi extension error',
          ),
        );
        break;
      default:
        break;
    }
  }

  Future<void> _cleanup() async {
    await _eventSub?.cancel();
    _eventSub = null;
    await _client?.stop();
    _client = null;
  }

  static String? _toolResultText(Object? result) {
    if (result is! Map) return result?.toString();
    final content = result['content'];
    if (content is List && content.isNotEmpty) {
      final first = content.first;
      if (first is Map) return first['text']?.toString();
    }
    return result.toString();
  }

  static _SelectedModel? _parseModelPath(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty || !trimmed.contains('/')) {
      return null;
    }
    final slash = trimmed.indexOf('/');
    return _SelectedModel(
      trimmed.substring(0, slash),
      trimmed.substring(slash + 1),
    );
  }
}

class _SelectedModel {
  final String provider;
  final String model;

  const _SelectedModel(this.provider, this.model);
}
