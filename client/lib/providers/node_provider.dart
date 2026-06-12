import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/node_state.dart';
import '../services/session_cache.dart';
import '../services/websocket_service.dart';

const String _kHubUrlPrefKey = 'mobilepi.hubUrl';
const String _kTenantKeyPrefKey = 'mobilepi.tenantKey';
const String _kCursorPrefKey = 'mobilepi.cursors';
const Duration _kStreamingNotifyInterval = Duration(milliseconds: 80);

class TaskState {
  final String id;
  final String nodeId;
  final String projectId;
  final String projectPath;
  final String? sessionId;
  final String? sessionPath;
  final String agentType;
  final String? piInstanceId;
  final String? model;
  final String title;
  final String status; // idle|running|waitingDecision|error|completed|history
  final String? streamingText;

  /// Structured streaming text segments derived from protocol fields.
  /// Rendering must use this instead of parsing tags out of [streamingText].
  final List<MessagePart> streamingParts;

  final List<PiSessionMessageInfo> messages;
  final int? progressPercent;
  final int? linesAdded;
  final int? linesRemoved;
  final int? nextBeforeIndex;
  final int? totalCount;
  final DateTime createdAt;

  /// Whether the model is currently thinking (structured boundary).
  /// `true` after `thinking: "start"`, `false` after `thinking: "end"`.
  final bool isThinking;

  /// Status labels (compaction, retry, etc.) shown transiently.
  final String? statusLabel;

  TaskState({
    required this.id,
    required this.nodeId,
    required this.projectId,
    required this.projectPath,
    this.sessionId,
    this.sessionPath,
    this.agentType = 'pi',
    this.piInstanceId,
    this.model,
    required this.title,
    this.status = 'idle',
    this.streamingText,
    this.streamingParts = const [],
    this.messages = const [],
    this.progressPercent,
    this.linesAdded,
    this.linesRemoved,
    this.nextBeforeIndex,
    this.totalCount,
    this.isThinking = false,
    this.statusLabel,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  TaskState copyWith({
    String? status,
    String? projectId,
    String? projectPath,
    String? sessionId,
    String? sessionPath,
    String? piInstanceId,
    String? model,
    String? streamingText,
    List<MessagePart>? streamingParts,
    List<PiSessionMessageInfo>? messages,
    int? progressPercent,
    int? linesAdded,
    int? linesRemoved,
    int? nextBeforeIndex,
    int? totalCount,
    bool? isThinking,
    String? statusLabel,
  }) {
    return TaskState(
      id: id,
      nodeId: nodeId,
      projectId: projectId ?? this.projectId,
      projectPath: projectPath ?? this.projectPath,
      sessionId: sessionId ?? this.sessionId,
      sessionPath: sessionPath ?? this.sessionPath,
      agentType: agentType,
      piInstanceId: piInstanceId ?? this.piInstanceId,
      model: model ?? this.model,
      title: title,
      status: status ?? this.status,
      streamingText: streamingText ?? this.streamingText,
      streamingParts: streamingParts ?? this.streamingParts,
      messages: messages ?? this.messages,
      progressPercent: progressPercent ?? this.progressPercent,
      linesAdded: linesAdded ?? this.linesAdded,
      linesRemoved: linesRemoved ?? this.linesRemoved,
      nextBeforeIndex: nextBeforeIndex ?? this.nextBeforeIndex,
      totalCount: totalCount ?? this.totalCount,
      isThinking: isThinking ?? this.isThinking,
      statusLabel: statusLabel ?? this.statusLabel,
      createdAt: createdAt,
    );
  }

  String get displayTitle {
    final userPreview = _firstMessagePreview(
      messages.where((message) => message.role == 'user'),
    );
    if (userPreview.isNotEmpty) return _singleLineTitle(userPreview);

    final messagePreview = _firstMessagePreview(messages);
    if (messagePreview.isNotEmpty) return _singleLineTitle(messagePreview);

    return _singleLineTitle(title);
  }
}

String _firstMessagePreview(Iterable<PiSessionMessageInfo> messages) {
  for (final message in messages) {
    final preview = message.structuredPreviewText;
    if (preview.isNotEmpty) return preview;
  }
  return '';
}

String _singleLineTitle(String text) {
  final singleLine = text.replaceAll('\n', ' ').trim();
  return singleLine.length > 80
      ? '${singleLine.substring(0, 80)}...'
      : singleLine;
}

/// Result of a remote directory listing.
class DirectoryListing {
  final String path;
  final bool isHome;
  final List<DirectoryEntry> entries;
  final String? error;

  const DirectoryListing({
    required this.path,
    required this.isHome,
    required this.entries,
    this.error,
  });
}

class DirectoryEntry {
  final String name;
  final String path;
  const DirectoryEntry({required this.name, required this.path});
}

class ProjectState {
  final String id;
  final String nodeId;
  final String path;
  final String name;
  final int sessionCount;
  final DateTime? lastSeenAt;

  const ProjectState({
    required this.id,
    required this.nodeId,
    required this.path,
    required this.name,
    this.sessionCount = 0,
    this.lastSeenAt,
  });
}

class ProjectSessionState {
  final String id;
  final String nodeId;
  final String projectId;
  final String title;
  final String status;
  final DateTime? updatedAt;
  final TaskState? task;

  const ProjectSessionState({
    required this.id,
    required this.nodeId,
    required this.projectId,
    required this.title,
    required this.status,
    this.updatedAt,
    this.task,
  });
}

/// 节点状态 Provider
///
/// 管理 WebSocket 连接、Node 列表、任务状态。
class NodeProvider extends ChangeNotifier {
  final WebSocketService _ws;
  final SessionCache _sessionCache;
  final bool _closeSessionCacheOnDispose;
  final Map<String, NodeState> _nodes = {};
  final Map<String, TaskState> _tasks = {};
  final Map<String, ValueNotifier<TaskState?>> _taskNotifiers = {};
  final Set<String> _pendingStreamingTaskNotifications = {};
  final ValueNotifier<List<TaskState>> _recentTasksNotifier =
      ValueNotifier<List<TaskState>>(const []);
  final Map<String, Map<String, int>> _cursorsByNode = {};
  final Map<String, Completer<DirectoryListing>> _pendingBrowse = {};
  final Map<String, Completer<String>> _pendingCreate = {};
  late final StreamSubscription<MobilePiMessage> _messageSub;
  late final StreamSubscription<bool> _connectionSub;
  Timer? _streamingNotifyTimer;
  Timer? _cursorSaveTimer;
  Timer? _sessionCacheSaveTimer;
  late String _hubUrl;
  late String _tenantKey;
  bool _connecting = false;
  bool _settingsLoaded = false;

  NodeProvider({WebSocketService? webSocketService, SessionCache? sessionCache})
    : _ws = webSocketService ?? WebSocketService(),
      _sessionCache = sessionCache ?? SessionCache.shared(),
      _closeSessionCacheOnDispose = sessionCache != null {
    _hubUrl = _ws.hubUrl;
    _tenantKey = _ws.tenantKey;
    _messageSub = _ws.messageStream.listen(_onMessage);
    _connectionSub = _ws.connectionStream.listen(_onConnectionChanged);
  }

  List<NodeState> get nodes => List.unmodifiable(_nodes.values);

  /// 按状态分类的任务
  List<TaskState> get runningTasks =>
      _tasks.values.where((t) => t.status == 'running').toList();
  List<TaskState> get waitingTasks =>
      _tasks.values.where((t) => t.status == 'waitingDecision').toList();
  List<TaskState> get idleTasks => _tasks.values
      .where(
        (t) =>
            t.status == 'idle' ||
            t.status == 'completed' ||
            t.status == 'error',
      )
      .toList();
  List<TaskState> get recentTasks {
    final tasks = _tasks.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(tasks);
  }

  ValueListenable<List<TaskState>> get recentTasksListenable =>
      _recentTasksNotifier;

  bool get isConnecting => _connecting;
  bool get isConnected => _ws.isConnected;
  bool get hasOnlineNodes => _nodes.values.any((n) => n.online);
  String get hubUrl => _hubUrl;
  String get tenantKey => _tenantKey;
  bool get hasTenantKey => _tenantKey.trim().isNotEmpty;

  Future<void> loadSettings() async {
    if (_settingsLoaded) return;
    _settingsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kHubUrlPrefKey)?.trim();
      if (saved != null && saved.isNotEmpty) {
        try {
          _ws.updateHubUrl(saved);
        } on FormatException {
          // 忽略坏的持久化值，沿用默认 URL
        }
      }
      final savedTenantKey = prefs.getString(_kTenantKeyPrefKey)?.trim();
      if (savedTenantKey != null && savedTenantKey.isNotEmpty) {
        _ws.updateTenantKey(savedTenantKey);
      }
      final rawCursors = prefs.getString(_kCursorPrefKey);
      if (rawCursors != null && rawCursors.isNotEmpty) {
        _restoreCursors(rawCursors);
      }
      await _hydrateSessionCache();
    } catch (_) {
      // SharedPreferences 在某些平台 / 测试里可能不可用
    }
    _hubUrl = _ws.hubUrl;
    _tenantKey = _ws.tenantKey;
    notifyListeners();
  }

  /// 更新 Hub URL：归一化 + 持久化 + 立刻重连。
  /// 失败时抛 [FormatException]。
  Future<void> setHubUrl(String url) async {
    final normalized = _ws.updateHubUrl(url);
    _hubUrl = normalized;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHubUrlPrefKey, normalized);
    } catch (_) {
      // 持久化失败不阻塞，本次运行仍生效
    }
    notifyListeners();
    connect();
  }

  /// 更新 Hub URL 和租户 key：归一化 + 持久化 + 立刻重连。
  Future<void> setHubConnection({
    required String url,
    required String tenantKey,
  }) async {
    final normalizedKey = WebSocketService.normalizeTenantKey(tenantKey);
    if (normalizedKey.isEmpty) {
      throw const FormatException('Key 不能为空');
    }
    final normalizedUrl = _ws.updateHubUrl(url);
    _ws.updateTenantKey(normalizedKey);
    _hubUrl = normalizedUrl;
    _tenantKey = normalizedKey;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHubUrlPrefKey, normalizedUrl);
      await prefs.setString(_kTenantKeyPrefKey, normalizedKey);
    } catch (_) {
      // 持久化失败不阻塞，本次运行仍生效
    }
    notifyListeners();
    connect();
  }

  void connect() {
    if (!hasTenantKey) {
      _connecting = false;
      notifyListeners();
      return;
    }
    if (_ws.isConnected || _connecting) return;
    _connecting = true;
    notifyListeners();
    _ws.connect();
  }

  void disconnect() {
    _ws.disconnect();
    _markAllOffline();
  }

  void refresh() {
    if (_ws.isConnected) {
      _connecting = true;
      notifyListeners();
      _ws.forceReconnect();
    } else {
      connect();
    }
  }

  /// app 从后台切回前台时调用：强制重连 + 差量同步，确保进度连续性。
  /// 即便 `_ws.isConnected` 仍为 true，移动端冻结后的 socket 也可能是僵尸，
  /// 故走 forceReconnect 重建连接（重连成功后 _onConnectionChanged 会 resume）。
  void onAppResumed() {
    if (!hasTenantKey) {
      debugPrint(
        'MobilePiLifecycle event=app_resumed action=skip_missing_tenant_key',
      );
      return;
    }
    debugPrint('MobilePiLifecycle event=app_resumed action=force_reconnect');
    _ws.forceReconnect();
  }

  void _onConnectionChanged(bool connected) {
    _connecting = false;
    if (connected) {
      _sendHelloAndResume();
    } else {
      _markAllOffline();
    }
    notifyListeners();
  }

  void _sendHelloAndResume() {
    _ws.sendHello(lastCursors: _cursorsByNode);
    for (final node in _nodes.values.where((node) => node.online)) {
      _ws.sendResume(node.nodeId, _cursorsByNode[node.nodeId] ?? const {});
    }
  }

  void _onMessage(MobilePiMessage message) {
    switch (message.type) {
      case MessageType.response:
        _handleProtocolResponse(message);
        break;
      case MessageType.event:
        _handleProtocolEvent(message);
        break;
      default:
        break;
    }
  }

  void _handleBrowseDirectoryResponse(
    Map<String, dynamic> payload, {
    required String responseTo,
  }) {
    final completer = _pendingBrowse.remove(responseTo);
    if (completer == null) return;
    final entries =
        (payload[ProtocolPayloadKeys.entries] as List<dynamic>?)
            ?.whereType<Map>()
            .map(
              (e) => DirectoryEntry(
                name: e['name']?.toString() ?? '',
                path: e['path']?.toString() ?? '',
              ),
            )
            .where((e) => e.name.isNotEmpty && e.path.isNotEmpty)
            .toList() ??
        const <DirectoryEntry>[];
    completer.complete(
      DirectoryListing(
        path: payload[ProtocolPayloadKeys.path]?.toString() ?? '',
        isHome: payload[ProtocolPayloadKeys.isHome] as bool? ?? false,
        entries: entries,
        error: payload[ProtocolPayloadKeys.error]?.toString(),
      ),
    );
  }

  void _handleCreateDirectoryResponse(
    Map<String, dynamic> payload, {
    required String responseTo,
  }) {
    final completer = _pendingCreate.remove(responseTo);
    if (completer == null) return;
    final error = payload[ProtocolPayloadKeys.error]?.toString();
    if (error != null && error.isNotEmpty) {
      completer.completeError(Exception(error));
      return;
    }
    completer.complete(payload[ProtocolPayloadKeys.path]?.toString() ?? '');
  }

  void _applyNodeSummary(Map<String, dynamic> payload, {required String from}) {
    final nodeId =
        payload[ProtocolPayloadKeys.nodeId] as String? ??
        _normalizeNodeId(from);
    final hostname = payload[ProtocolPayloadKeys.hostname] as String? ?? nodeId;
    final platform = payload[ProtocolPayloadKeys.platform] as String? ?? '';
    final agents =
        (payload[ProtocolPayloadKeys.agents] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];
    final piModels =
        (payload[ProtocolPayloadKeys.piModels] as List<dynamic>?)
            ?.whereType<Map>()
            .map((e) => PiModelInfo.fromJson(Map<String, dynamic>.from(e)))
            .where((m) => m.id.isNotEmpty)
            .toList() ??
        <PiModelInfo>[];
    final piSlashCommands =
        (payload[ProtocolPayloadKeys.piSlashCommands] as List<dynamic>?)
            ?.whereType<Map>()
            .map(
              (e) => PiSlashCommandInfo.fromJson(Map<String, dynamic>.from(e)),
            )
            .where((c) => c.name.isNotEmpty)
            .toList() ??
        <PiSlashCommandInfo>[];
    final piInstances =
        (payload[ProtocolPayloadKeys.piInstances] as List<dynamic>?)
            ?.whereType<Map>()
            .map((e) => PiInstanceInfo.fromJson(Map<String, dynamic>.from(e)))
            .where((instance) => instance.id.isNotEmpty)
            .toList() ??
        <PiInstanceInfo>[];
    final piState = payload[ProtocolPayloadKeys.piState] is Map
        ? Map<String, dynamic>.from(payload[ProtocolPayloadKeys.piState] as Map)
        : null;
    final piMessages =
        (payload[ProtocolPayloadKeys.piMessages] as List<dynamic>?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        <Map<String, dynamic>>[];
    final piSessions =
        (payload[ProtocolPayloadKeys.piSessions] as List<dynamic>?)
            ?.whereType<Map>()
            .map((e) => PiSessionInfo.fromJson(Map<String, dynamic>.from(e)))
            .where((session) => session.id.isNotEmpty)
            .toList() ??
        <PiSessionInfo>[];

    _nodes[nodeId] = NodeState(
      nodeId: nodeId,
      hostname: hostname,
      platform: platform,
      agents: agents,
      piModels: piModels,
      piDefaultModel: payload[ProtocolPayloadKeys.piDefaultModel]?.toString(),
      piSlashCommands: piSlashCommands,
      piInstances: piInstances,
      piState: piState,
      piMessages: piMessages,
      piSessions: piSessions,
      online: payload[ProtocolPayloadKeys.online] as bool? ?? true,
      lastSeenAt: DateTime.now(),
    );
    _syncPiSessions(nodeId, piSessions);

    notifyListeners();
  }

  void _handleProtocolResponse(MobilePiMessage message) {
    final payload = message.payload;
    final responseTo = payload[ProtocolPayloadKeys.responseTo]?.toString();
    if (responseTo != null) {
      if (_pendingBrowse.containsKey(responseTo)) {
        _handleBrowseDirectoryResponse(payload, responseTo: responseTo);
        return;
      }
      if (_pendingCreate.containsKey(responseTo)) {
        _handleCreateDirectoryResponse(payload, responseTo: responseTo);
        return;
      }
    }
    if (payload['sessionPath'] != null && payload['messages'] != null) {
      _handleSessionMessagesResponse(payload);
      return;
    }

    final nodeSummaries =
        (payload[ProtocolPayloadKeys.nodeSummaries] as List<dynamic>?)
            ?.whereType<Map>()
            .map((summary) => Map<String, dynamic>.from(summary))
            .toList() ??
        const <Map<String, dynamic>>[];
    Logger('NodeProvider').info(
      'event=node_summaries.received ${logFields({'count': nodeSummaries.length, 'from': message.from, 'responseTo': responseTo})}',
    );
    for (final summary in nodeSummaries) {
      final nodeId =
          summary[ProtocolPayloadKeys.nodeId]?.toString() ??
          _normalizeNodeId(message.from);
      _applyNodeSummary(summary, from: nodeId);
      _ws.sendResume(nodeId, _cursorsByNode[nodeId] ?? const {});
    }

    final nodeSummary = payload[ProtocolPayloadKeys.nodeSummary];
    if (nodeSummary is Map) {
      final summary = Map<String, dynamic>.from(nodeSummary);
      final nodeId =
          summary[ProtocolPayloadKeys.nodeId]?.toString() ??
          _normalizeNodeId(message.from);
      Logger('NodeProvider').info(
        'event=node_summary.received ${logFields({'nodeId': nodeId, 'from': message.from})}',
      );
      _applyNodeSummary(summary, from: nodeId);
    }

    final nodeId = _normalizeNodeId(message.from);
    final truncatedStreams =
        (payload[ProtocolPayloadKeys.truncatedStreams] as List<dynamic>?)
            ?.whereType<Map>()
            .map((stream) => Map<String, dynamic>.from(stream))
            .toList() ??
        const <Map<String, dynamic>>[];
    if (truncatedStreams.isNotEmpty) {
      for (final stream in truncatedStreams) {
        _applyTruncatedStreamSnapshot(nodeId, stream);
      }
    }

    final events =
        (payload[ProtocolPayloadKeys.events] as List<dynamic>?)
            ?.whereType<Map>()
            .map((event) => Map<String, dynamic>.from(event))
            .toList() ??
        const <Map<String, dynamic>>[];
    if (events.isNotEmpty) {
      for (final event in events) {
        _applyProtocolEvent(nodeId, event, notify: false);
      }
      _notifyNow();
    } else if (truncatedStreams.isNotEmpty) {
      _notifyNow();
    }

    if (payload[ProtocolPayloadKeys.hasMore] == true) {
      _ws.sendResume(nodeId, _cursorsByNode[nodeId] ?? const {});
    }
  }

  void _applyTruncatedStreamSnapshot(
    String nodeId,
    Map<String, dynamic> stream,
  ) {
    final snapshot = stream['snapshot'];
    if (snapshot is Map) {
      _applyProtocolEvent(
        nodeId,
        Map<String, dynamic>.from(snapshot),
        notify: false,
      );
      return;
    }

    final streamId = stream[ProtocolPayloadKeys.streamId]?.toString();
    final latestSeq = _intValue(stream['latestSeq']);
    if (streamId == null || streamId.isEmpty || latestSeq == null) return;

    final nodeCursors = _cursorsByNode.putIfAbsent(
      nodeId,
      () => <String, int>{},
    );
    if (latestSeq > (nodeCursors[streamId] ?? 0)) {
      nodeCursors[streamId] = latestSeq;
      _scheduleCursorSave();
    }
  }

  void _handleProtocolEvent(MobilePiMessage message) {
    _applyProtocolEvent(
      _normalizeNodeId(message.from),
      message.payload,
      notify: true,
    );
  }

  void _applyProtocolEvent(
    String nodeId,
    Map<String, dynamic> event, {
    required bool notify,
  }) {
    final streamId = event[ProtocolPayloadKeys.streamId]?.toString();
    final seq = _intValue(event[ProtocolPayloadKeys.seq]);
    final eventType = event[ProtocolPayloadKeys.eventType]?.toString();
    final rawPayload = event[ProtocolPayloadKeys.eventPayload];
    if (streamId == null ||
        streamId.isEmpty ||
        seq == null ||
        eventType == null ||
        rawPayload is! Map) {
      return;
    }

    final nodeCursors = _cursorsByNode.putIfAbsent(
      nodeId,
      () => <String, int>{},
    );
    final currentSeq = nodeCursors[streamId] ?? 0;
    if (seq <= currentSeq) return;

    final taskPayload = Map<String, dynamic>.from(rawPayload);
    taskPayload['taskId'] ??= event['taskId'];
    _normalizeTaskPayloadFromEvent(eventType, taskPayload);
    _applyTaskUpdatePayload(
      nodeId: nodeId,
      payload: taskPayload,
      notify: notify,
    );
    nodeCursors[streamId] = seq;
    _scheduleCursorSave();
  }

  void _normalizeTaskPayloadFromEvent(
    String eventType,
    Map<String, dynamic> payload,
  ) {
    switch (eventType) {
      case 'task.created':
      case 'task.started':
      case 'task.status':
        payload['status'] ??= 'running';
        break;
      case 'task.completed':
        payload['status'] = 'completed';
        break;
      case 'task.aborted':
        payload['status'] = 'idle';
        break;
      case 'task.error':
        payload['status'] = 'error';
        payload['streamingText'] ??= payload['message']?.toString();
        break;
      case 'task.output.delta':
        payload['status'] ??= 'running';
        payload['streamingDelta'] ??= payload['text']?.toString();
        break;
      case 'task.output.snapshot':
        payload['status'] ??= 'running';
        payload['streamingText'] ??= payload['text']?.toString();
        break;
      case 'task.progress':
        payload['status'] ??= 'running';
        payload['progressPercent'] ??= _intValue(payload['percent']);
        break;
    }
  }

  void _applyTaskUpdatePayload({
    required String nodeId,
    required Map<String, dynamic> payload,
    bool notify = true,
  }) {
    final taskId = payload['taskId'] as String? ?? '';
    final status = payload['status'] as String? ?? 'running';
    final streamingText = payload['streamingText'] as String?;
    final streamingDelta = payload['streamingDelta'] as String?;
    final messages = (payload[ProtocolPayloadKeys.piMessages] as List<dynamic>?)
        ?.whereType<Map>()
        .map((e) => PiSessionMessageInfo.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final model = payload[ProtocolPayloadKeys.model]?.toString();
    final sessionId = payload['sessionId']?.toString();
    final sessionPath = payload[ProtocolPayloadKeys.sessionPath]?.toString();
    final piInstanceId = payload[ProtocolPayloadKeys.piInstanceId]?.toString();
    final progressPercent = payload['progressPercent'] as int?;
    final linesAdded = payload['linesAdded'] as int?;
    final linesRemoved = payload['linesRemoved'] as int?;
    final projectPath = payload[ProtocolPayloadKeys.projectPath]?.toString();
    final project = projectPath == null || projectPath.isEmpty
        ? defaultProjectForNode(nodeId)
        : ProjectState(
            id: _projectId(nodeId, projectPath),
            nodeId: nodeId,
            path: projectPath,
            name: _projectName(projectPath),
          );

    // --- Structured fields ---
    final toolCallRaw = payload[ProtocolPayloadKeys.toolCall];
    final toolResultRaw = payload[ProtocolPayloadKeys.toolResult];
    final thinkingRaw = payload[ProtocolPayloadKeys.thinking]?.toString();
    final statusLabel = payload[ProtocolPayloadKeys.statusLabel]?.toString();

    if (taskId.isEmpty) return;

    final existing = _tasks[taskId];

    // Thinking boundary
    bool? isThinking;
    if (thinkingRaw == 'start') isThinking = true;
    if (thinkingRaw == 'end') isThinking = false;
    if (status != 'running' && thinkingRaw == null) isThinking = false;

    // Pure text delta
    String? nextStreamingText = streamingText;
    if (nextStreamingText == null && streamingDelta != null) {
      nextStreamingText = '${existing?.streamingText ?? ''}$streamingDelta';
    }

    final nextStreamingParts = _structuredStreamingParts(
      existing: existing,
      streamingText: streamingText,
      streamingDelta: streamingDelta,
      toolCallRaw: toolCallRaw,
      toolResultRaw: toolResultRaw,
      isThinking: isThinking ?? existing?.isThinking ?? false,
    );

    final incremental = _isRunningIncrementalUpdate(
      existing: existing,
      status: status,
      streamingText: streamingText,
      streamingDelta: streamingDelta,
      toolCallRaw: toolCallRaw,
      toolResultRaw: toolResultRaw,
      thinkingRaw: thinkingRaw,
      statusLabel: statusLabel,
      progressPercent: progressPercent,
      linesAdded: linesAdded,
      linesRemoved: linesRemoved,
    );

    if (existing != null) {
      _setTask(
        existing.copyWith(
          status: status,
          sessionId: sessionId,
          sessionPath: sessionPath,
          piInstanceId: piInstanceId,
          model: model,
          streamingText: nextStreamingText,
          streamingParts: nextStreamingParts,
          messages: messages,
          progressPercent: progressPercent,
          linesAdded: linesAdded,
          linesRemoved: linesRemoved,
          isThinking: isThinking,
          statusLabel: statusLabel,
        ),
        notifyTask: !incremental,
      );
    } else {
      _setTask(
        TaskState(
          id: taskId,
          nodeId: nodeId,
          projectId: project.id,
          projectPath: project.path,
          sessionId: sessionId ?? _sessionIdForNode(nodeId),
          sessionPath: sessionPath,
          piInstanceId: piInstanceId,
          model: model,
          title: payload[ProtocolPayloadKeys.title]?.toString() ?? '任务 $taskId',
          status: status,
          streamingText: nextStreamingText,
          streamingParts: nextStreamingParts ?? const [],
          messages: messages ?? const [],
          progressPercent: progressPercent,
          linesAdded: linesAdded,
          linesRemoved: linesRemoved,
          isThinking: isThinking ?? false,
          statusLabel: statusLabel,
        ),
      );
    }
    _scheduleSessionCacheSave();

    if (incremental) {
      if (!notify) {
        _pendingStreamingTaskNotifications.add(taskId);
        return;
      }
      _notifyStreamingSoon(taskId);
    } else {
      if (!notify) return;
      _notifyNow();
    }
    _pruneOldTasks();
  }

  bool _isRunningIncrementalUpdate({
    required TaskState? existing,
    required String status,
    required String? streamingText,
    required String? streamingDelta,
    required dynamic toolCallRaw,
    required dynamic toolResultRaw,
    required String? thinkingRaw,
    required String? statusLabel,
    required int? progressPercent,
    required int? linesAdded,
    required int? linesRemoved,
  }) {
    if (existing == null || status != 'running') return false;
    return streamingText != null ||
        streamingDelta != null ||
        toolCallRaw is Map ||
        toolResultRaw is Map ||
        thinkingRaw != null ||
        statusLabel != null ||
        progressPercent != null ||
        linesAdded != null ||
        linesRemoved != null;
  }

  List<MessagePart>? _structuredStreamingParts({
    required TaskState? existing,
    required String? streamingText,
    required String? streamingDelta,
    required dynamic toolCallRaw,
    required dynamic toolResultRaw,
    required bool isThinking,
  }) {
    if (streamingText == null &&
        streamingDelta == null &&
        toolCallRaw is! Map &&
        toolResultRaw is! Map) {
      return null;
    }

    if (streamingText != null) {
      final part = isThinking
          ? MessagePart.thinking(streamingText)
          : MessagePart.text(streamingText);
      return [part];
    }

    final parts = List<MessagePart>.from(existing?.streamingParts ?? const []);
    if (toolCallRaw is Map) {
      parts.add(
        MessagePart.toolCall(
          toolCallRaw['name']?.toString() ?? '',
          id: toolCallRaw['id']?.toString(),
          input: toolCallRaw['input'] is Map
              ? Map<String, dynamic>.from(toolCallRaw['input'] as Map)
              : null,
        ),
      );
    }
    if (toolResultRaw is Map) {
      parts.add(
        MessagePart.toolResult(
          name: toolResultRaw['name']?.toString() ?? '',
          id: toolResultRaw['id']?.toString(),
          status: toolResultRaw['isError'] == true ? '失败' : '成功',
          text: toolResultRaw['text']?.toString(),
        ),
      );
    }

    final delta = streamingDelta;
    if (delta == null || delta.isEmpty) {
      return parts;
    }

    if (parts.isEmpty || parts.last.type != _streamingPartType(isThinking)) {
      parts.add(
        isThinking ? MessagePart.thinking(delta) : MessagePart.text(delta),
      );
    } else {
      final last = parts.removeLast();
      final text = '${last.text ?? ''}$delta';
      parts.add(
        isThinking ? MessagePart.thinking(text) : MessagePart.text(text),
      );
    }
    return parts;
  }

  MessagePartType _streamingPartType(bool isThinking) {
    return isThinking ? MessagePartType.thinking : MessagePartType.text;
  }

  static String? _messageSourceIndexKey(PiSessionMessageInfo m) {
    final sourceIndex = m.sourceIndex;
    return sourceIndex == null ? null : 'idx:$sourceIndex';
  }

  /// Fallback key for legacy cached/session preview messages that predate
  /// sourceIndex. New paginated session responses should use sourceIndex.
  static String _legacyMessageDedupKey(PiSessionMessageInfo m) {
    final partSig = m.parts
        .map((p) => '${p.type.name}/${p.name ?? ''}/${(p.text ?? '').length}')
        .join('|');
    final ts = m.timestamp?.toIso8601String() ?? '';
    return 'legacy:${m.role}#$ts#${m.text.length}#$partSig';
  }

  void _handleSessionMessagesResponse(Map<String, dynamic> payload) {
    final sessionPath = payload['sessionPath'] as String? ?? '';
    if (sessionPath.isEmpty) return;

    final rawMessages = payload['messages'] as List<dynamic>? ?? const [];
    final newMessages = rawMessages
        .whereType<Map>()
        .map((e) => PiSessionMessageInfo.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    final totalCount = payload['totalCount'] as int? ?? 0;
    final nextBeforeIndex = payload['nextBeforeIndex'] as int?;

    TaskState? targetTask;
    for (final task in _tasks.values) {
      if (task.sessionPath == sessionPath) {
        targetTask = task;
        break;
      }
    }

    if (targetTask == null) return;

    final existingSourceIndexes = targetTask.messages
        .map(_messageSourceIndexKey)
        .whereType<String>()
        .toSet();
    final existingLegacyKeys = targetTask.messages
        .where((message) => message.sourceIndex == null)
        .map(_legacyMessageDedupKey)
        .toSet();
    final uniqueNewMessages = <PiSessionMessageInfo>[];
    for (final message in newMessages) {
      final sourceIndexKey = _messageSourceIndexKey(message);
      if (sourceIndexKey != null) {
        if (existingSourceIndexes.add(sourceIndexKey)) {
          uniqueNewMessages.add(message);
        }
        continue;
      }

      final legacyKey = _legacyMessageDedupKey(message);
      if (existingLegacyKeys.add(legacyKey)) {
        uniqueNewMessages.add(message);
      }
    }

    final updatedMessages = [...uniqueNewMessages, ...targetTask.messages];

    _setTask(
      targetTask.copyWith(
        messages: updatedMessages,
        nextBeforeIndex: nextBeforeIndex,
        totalCount: totalCount,
      ),
    );
    _scheduleSessionCacheSave();

    notifyListeners();
  }

  /// 创建并发送任务指令
  String sendTaskCommand(
    String prompt, {
    String nodeId = '',
    String? projectId,
    String? projectPath,
    String agentType = 'pi',
    String? piInstanceId,
    String? model,
  }) {
    final taskId = const Uuid().v4();

    // 选择目标 Node（取第一个在线 Node）
    String targetNodeId = nodeId;
    if (targetNodeId.isEmpty) {
      final onlineNodes = _nodes.values.where((n) => n.online).toList();
      if (onlineNodes.isEmpty) return taskId;
      targetNodeId = onlineNodes.first.nodeId;
    }
    final project = projectId == null
        ? defaultProjectForNode(targetNodeId)
        : ProjectState(
            id: projectId,
            nodeId: targetNodeId,
            path: projectPath ?? projectId,
            name: _projectName(projectPath ?? projectId),
          );

    // 本地预创建任务
    _setTask(
      TaskState(
        id: taskId,
        nodeId: targetNodeId,
        projectId: project.id,
        projectPath: project.path,
        sessionId: taskId,
        agentType: agentType,
        piInstanceId: piInstanceId,
        model: model,
        title: prompt.length > 80 ? '${prompt.substring(0, 80)}...' : prompt,
        messages: [PiSessionMessageInfo(role: 'user', text: prompt)],
        status: 'running',
      ),
    );
    _scheduleSessionCacheSave();
    notifyListeners();

    _ws.sendTaskCommand(
      targetNodeId,
      taskId,
      prompt,
      agentType: agentType,
      piInstanceId: piInstanceId,
      model: model,
      projectPath: project.path,
    );

    return taskId;
  }

  void sendPanic(String nodeId, {String? taskId}) {
    _ws.sendPanic(nodeId, taskId: taskId);
  }

  void sendSteer(String taskId, String message, {String? model}) {
    final task = _tasks[taskId];
    if (task == null) return;
    _appendLocalUserMessage(task, message);
    _ws.sendSteerCommand(
      task.nodeId,
      taskId,
      message,
      sessionPath: task.sessionPath,
      model: model,
    );
  }

  void sendComposerMessage(String taskId, String message, {String? model}) {
    final task = _tasks[taskId];
    if (task == null) return;
    if (_acceptsSteering(task.status)) {
      sendSteer(taskId, message, model: model);
    } else {
      sendFollowUp(taskId, message, model: model);
    }
  }

  bool _acceptsSteering(String status) =>
      status == 'running' || status == 'waitingDecision';

  void sendFollowUp(String taskId, String message, {String? model}) {
    final task = _tasks[taskId];
    if (task == null) return;
    _appendLocalUserMessage(task, message);
    _ws.sendFollowUpCommand(
      task.nodeId,
      taskId,
      message,
      sessionPath: task.sessionPath,
      model: model,
    );
  }

  void _appendLocalUserMessage(TaskState task, String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;

    _setTask(
      task.copyWith(
        messages: [
          ...task.messages,
          PiSessionMessageInfo(
            role: 'user',
            text: trimmed,
            timestamp: DateTime.now(),
          ),
        ],
      ),
    );
    _scheduleSessionCacheSave();
    notifyListeners();
  }

  Future<void> requestSessionMessages(
    String nodeId,
    String taskId,
    String sessionPath, {
    int limit = 20,
    int? beforeIndex,
  }) async {
    if (!_ws.isConnected) return;
    _ws.sendSessionMessagesRequest(
      nodeId,
      sessionPath,
      taskId: taskId,
      limit: limit,
      beforeIndex: beforeIndex,
    );
  }

  /// Browse a directory on the remote node.
  ///
  /// If [path] is null/empty the daemon returns its home directory.
  Future<DirectoryListing> browseDirectory(String nodeId, {String? path}) {
    if (!_ws.isConnected) {
      return Future.error(StateError('未连接到 Hub'));
    }
    final messageId = _ws.sendBrowseDirectoryRequest(nodeId, path: path);
    final completer = Completer<DirectoryListing>();
    _pendingBrowse[messageId] = completer;
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pendingBrowse.remove(messageId);
        throw TimeoutException('浏览目录超时');
      },
    );
  }

  /// Create a directory under [parentPath]. Returns the new absolute path.
  Future<String> createDirectory(
    String nodeId, {
    required String parentPath,
    required String name,
  }) {
    if (!_ws.isConnected) {
      return Future.error(StateError('未连接到 Hub'));
    }
    final messageId = _ws.sendCreateDirectoryRequest(
      nodeId,
      parentPath: parentPath,
      name: name,
    );
    final completer = Completer<String>();
    _pendingCreate[messageId] = completer;
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pendingCreate.remove(messageId);
        throw TimeoutException('创建目录超时');
      },
    );
  }

  TaskState? getTask(String taskId) => _tasks[taskId];

  ValueListenable<TaskState?> taskListenable(String taskId) {
    return _taskNotifiers.putIfAbsent(
      taskId,
      () => ValueNotifier<TaskState?>(_tasks[taskId]),
    );
  }

  /// 从本地列表中移除一个任务（用于首页左滑删除）。
  /// 仅清理客户端缓存，不影响远端会话历史。
  void removeTask(String taskId) {
    if (_removeTaskState(taskId) != null) {
      unawaited(_sessionCache.deleteTask(taskId));
      notifyListeners();
    }
  }

  NodeState? getNode(String nodeId) => _nodes[nodeId];

  ProjectState defaultProjectForNode(String nodeId) {
    final node = _nodes[nodeId];
    final path = _projectPathFromNode(node);
    return ProjectState(
      id: _projectId(nodeId, path),
      nodeId: nodeId,
      path: path,
      name: _projectName(path),
      sessionCount: sessionsForProject(nodeId, _projectId(nodeId, path)).length,
      lastSeenAt: node?.lastSeenAt,
    );
  }

  List<ProjectState> projectsForNode(String nodeId) {
    final node = _nodes[nodeId];
    final projects = <String, ProjectState>{};

    void put(ProjectState project) {
      projects[project.id] = project;
    }

    final defaultProject = defaultProjectForNode(nodeId);
    put(defaultProject);

    for (final task in _tasks.values.where((task) => task.nodeId == nodeId)) {
      put(
        ProjectState(
          id: task.projectId,
          nodeId: nodeId,
          path: task.projectPath,
          name: _projectName(task.projectPath),
          sessionCount: sessionsForProject(nodeId, task.projectId).length,
          lastSeenAt: task.createdAt,
        ),
      );
    }

    final result =
        projects.values.map((project) {
          final sessions = sessionsForProject(nodeId, project.id);
          return ProjectState(
            id: project.id,
            nodeId: project.nodeId,
            path: project.path,
            name: project.name,
            sessionCount: sessions.length,
            lastSeenAt: sessions.isNotEmpty
                ? sessions.first.updatedAt
                : node?.lastSeenAt,
          );
        }).toList()..sort((a, b) {
          final aTime = a.lastSeenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bTime = b.lastSeenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bTime.compareTo(aTime);
        });
    return List.unmodifiable(result);
  }

  List<ProjectSessionState> sessionsForProject(
    String nodeId,
    String projectId,
  ) {
    final sessions = <String, ProjectSessionState>{};
    final node = _nodes[nodeId];
    final activeSessionId = _sessionIdForNode(nodeId);
    final defaultProjectId = _projectId(nodeId, _projectPathFromNode(node));

    for (final task in _tasks.values.where(
      (task) => task.nodeId == nodeId && task.projectId == projectId,
    )) {
      final sessionId = task.sessionId ?? task.id;
      sessions[sessionId] = ProjectSessionState(
        id: sessionId,
        nodeId: nodeId,
        projectId: projectId,
        title: task.title,
        status: task.status,
        updatedAt: task.createdAt,
        task: task,
      );
    }

    if (activeSessionId != null && projectId == defaultProjectId) {
      sessions.putIfAbsent(
        activeSessionId,
        () => ProjectSessionState(
          id: activeSessionId,
          nodeId: nodeId,
          projectId: projectId,
          title: 'Pi session ${_shortId(activeSessionId)}',
          status: node?.online == true ? 'running' : 'idle',
          updatedAt: node?.lastSeenAt,
        ),
      );
    }

    final result = sessions.values.toList()
      ..sort((a, b) {
        final aTime = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });
    return List.unmodifiable(result);
  }

  void _markAllOffline() {
    for (final entry in _nodes.entries) {
      _nodes[entry.key] = entry.value.copyWith(online: false);
    }
    notifyListeners();
  }

  void _syncPiSessions(String nodeId, List<PiSessionInfo> sessions) {
    for (final session in sessions) {
      final taskId = _piSessionTaskId(nodeId, session.id);
      final existing = _tasks[taskId];
      if (existing?.status == 'running') continue;

      final projectPath = session.cwd.trim().isEmpty
          ? _projectPathFromNode(_nodes[nodeId])
          : session.cwd.trim();
      final title = session.displayTitle;

      // 详情页可能已通过分页加载了更完整的消息窗口（totalCount 非空即代表
      // 收到过 session.messages 响应）。此处的周期性会话列表同步只携带预览，
      // 若直接覆盖会把已加载的消息和分页状态清空 → 详情页瞬间变空白。
      // 因此当已有加载窗口时，保留既有 messages / 分页游标。
      final preserveWindow = existing != null && existing.totalCount != null;

      _setTask(
        TaskState(
          id: taskId,
          nodeId: nodeId,
          projectId: _projectId(nodeId, projectPath),
          projectPath: projectPath,
          sessionId: session.id,
          sessionPath: session.path,
          title: title.length > 80 ? '${title.substring(0, 80)}...' : title,
          status: 'history',
          messages: preserveWindow ? existing.messages : session.messages,
          nextBeforeIndex: preserveWindow ? existing.nextBeforeIndex : null,
          totalCount: preserveWindow ? existing.totalCount : null,
          createdAt: session.updatedAt,
        ),
      );
    }
    _pruneOldTasks();
    _scheduleSessionCacheSave();
  }

  void _pruneOldTasks() {
    const maxTasks = 200;
    if (_tasks.length <= maxTasks) return;
    final toRemove = _tasks.entries
        .where((e) => e.value.status != 'running')
        .map((e) => e.key)
        .take(_tasks.length - maxTasks)
        .toList();
    for (final key in toRemove) {
      _removeTaskState(key);
      unawaited(_sessionCache.deleteTask(key));
    }
  }

  void _setTask(TaskState task, {bool notifyTask = true}) {
    _tasks[task.id] = task;
    if (notifyTask) {
      _pendingStreamingTaskNotifications.remove(task.id);
      _taskNotifiers[task.id]?.value = task;
    }
    _refreshRecentTasks();
  }

  TaskState? _removeTaskState(String taskId) {
    final removed = _tasks.remove(taskId);
    if (removed != null) {
      _pendingStreamingTaskNotifications.remove(taskId);
      _taskNotifiers[taskId]?.value = null;
      _refreshRecentTasks();
    }
    return removed;
  }

  void _refreshRecentTasks() {
    final next = recentTasks;
    if (_taskListShallowEqual(_recentTasksNotifier.value, next)) return;
    _recentTasksNotifier.value = next;
  }

  bool _taskListShallowEqual(List<TaskState> a, List<TaskState> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final ta = a[i];
      final tb = b[i];
      if (ta.id != tb.id ||
          ta.status != tb.status ||
          ta.progressPercent != tb.progressPercent ||
          ta.displayTitle != tb.displayTitle ||
          ta.nodeId != tb.nodeId ||
          ta.projectPath != tb.projectPath ||
          ta.model != tb.model ||
          ta.createdAt != tb.createdAt) {
        return false;
      }
    }
    return true;
  }

  void _notifyNow() {
    _streamingNotifyTimer?.cancel();
    _streamingNotifyTimer = null;
    _flushPendingStreamingTaskNotifications();
    notifyListeners();
  }

  void _notifyStreamingSoon(String taskId) {
    _pendingStreamingTaskNotifications.add(taskId);
    if (_streamingNotifyTimer?.isActive == true) return;
    _streamingNotifyTimer = Timer(_kStreamingNotifyInterval, () {
      _streamingNotifyTimer = null;
      _flushPendingStreamingTaskNotifications();
    });
  }

  void _flushPendingStreamingTaskNotifications() {
    if (_pendingStreamingTaskNotifications.isEmpty) return;
    final taskIds = List<String>.from(_pendingStreamingTaskNotifications);
    _pendingStreamingTaskNotifications.clear();
    for (final taskId in taskIds) {
      final notifier = _taskNotifiers[taskId];
      if (notifier == null) continue;
      notifier.value = _tasks[taskId];
    }
  }

  void _restoreCursors(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    _cursorsByNode.clear();
    for (final nodeEntry in decoded.entries) {
      final nodeId = nodeEntry.key?.toString();
      final streams = nodeEntry.value;
      if (nodeId == null || nodeId.isEmpty || streams is! Map) continue;
      final nodeCursors = <String, int>{};
      for (final streamEntry in streams.entries) {
        final streamId = streamEntry.key?.toString();
        final seq = _intValue(streamEntry.value);
        if (streamId != null && streamId.isNotEmpty && seq != null) {
          nodeCursors[streamId] = seq;
        }
      }
      _cursorsByNode[nodeId] = nodeCursors;
    }
  }

  void _scheduleCursorSave() {
    if (_cursorSaveTimer?.isActive == true) return;
    _cursorSaveTimer = Timer(const Duration(seconds: 1), () {
      _cursorSaveTimer = null;
      unawaited(_persistCursors());
    });
  }

  Future<void> _persistCursors() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCursorPrefKey, jsonEncode(_cursorsByNode));
    } catch (_) {
      // Cursor persistence is an optimization; replay still works in-memory.
    }
  }

  Future<void> _hydrateSessionCache() async {
    try {
      final snapshots = await _sessionCache.loadRecent();
      if (snapshots.isEmpty) return;
      for (final snapshot in snapshots.reversed) {
        final task = _taskFromCacheSnapshot(snapshot);
        if (task != null) {
          _setTask(task);
        }
      }
    } catch (_) {
      // Session cache is an optimization; network resume remains authoritative.
    }
  }

  void _scheduleSessionCacheSave() {
    if (_sessionCacheSaveTimer?.isActive == true) return;
    _sessionCacheSaveTimer = Timer(const Duration(milliseconds: 500), () {
      _sessionCacheSaveTimer = null;
      unawaited(_persistSessionCache());
    });
  }

  Future<void> _persistSessionCache() async {
    try {
      final now = DateTime.now();
      await _sessionCache.saveSnapshots(
        _tasks.values.map(
          (task) => SessionSnapshot(
            taskId: task.id,
            nodeId: task.nodeId,
            updatedAt: now,
            payload: _taskToCachePayload(task),
          ),
        ),
      );
    } catch (_) {
      // Session cache is a cold-start optimization; never block live sync.
    }
  }

  Map<String, dynamic> _taskToCachePayload(TaskState task) {
    return {
      'id': task.id,
      'nodeId': task.nodeId,
      'projectId': task.projectId,
      'projectPath': task.projectPath,
      if (task.sessionId != null) 'sessionId': task.sessionId,
      if (task.sessionPath != null) 'sessionPath': task.sessionPath,
      'agentType': task.agentType,
      if (task.piInstanceId != null) 'piInstanceId': task.piInstanceId,
      if (task.model != null) 'model': task.model,
      'title': task.title,
      'status': task.status,
      if (task.streamingText != null) 'streamingText': task.streamingText,
      if (task.streamingParts.isNotEmpty)
        'streamingParts': task.streamingParts
            .map((part) => part.toJson())
            .toList(),
      if (task.messages.isNotEmpty)
        'messages': task.messages.map((message) => message.toJson()).toList(),
      if (task.progressPercent != null) 'progressPercent': task.progressPercent,
      if (task.linesAdded != null) 'linesAdded': task.linesAdded,
      if (task.linesRemoved != null) 'linesRemoved': task.linesRemoved,
      if (task.nextBeforeIndex != null) 'nextBeforeIndex': task.nextBeforeIndex,
      if (task.totalCount != null) 'totalCount': task.totalCount,
      'createdAt': task.createdAt.toIso8601String(),
      'isThinking': task.isThinking,
      if (task.statusLabel != null) 'statusLabel': task.statusLabel,
    };
  }

  TaskState? _taskFromCacheSnapshot(SessionSnapshot snapshot) {
    final json = snapshot.payload;
    final taskId = json['id']?.toString();
    final nodeId = json['nodeId']?.toString() ?? snapshot.nodeId;
    final projectId = json['projectId']?.toString();
    final projectPath = json['projectPath']?.toString();
    final title = json['title']?.toString();
    if (taskId == null ||
        taskId.isEmpty ||
        nodeId.isEmpty ||
        projectId == null ||
        projectId.isEmpty ||
        projectPath == null ||
        projectPath.isEmpty ||
        title == null) {
      return null;
    }
    final streamingParts =
        (json['streamingParts'] as List<dynamic>?)
            ?.whereType<Map>()
            .map(
              (part) => MessagePart.fromJson(Map<String, dynamic>.from(part)),
            )
            .toList() ??
        const <MessagePart>[];
    final messages =
        (json['messages'] as List<dynamic>?)
            ?.whereType<Map>()
            .map(
              (message) => PiSessionMessageInfo.fromJson(
                Map<String, dynamic>.from(message),
              ),
            )
            .toList() ??
        const <PiSessionMessageInfo>[];
    return TaskState(
      id: taskId,
      nodeId: nodeId,
      projectId: projectId,
      projectPath: projectPath,
      sessionId: json['sessionId']?.toString(),
      sessionPath: json['sessionPath']?.toString(),
      agentType: json['agentType']?.toString() ?? 'pi',
      piInstanceId: json['piInstanceId']?.toString(),
      model: json['model']?.toString(),
      title: title,
      status: json['status']?.toString() ?? 'history',
      streamingText: json['streamingText']?.toString(),
      streamingParts: streamingParts,
      messages: messages,
      progressPercent: _intValue(json['progressPercent']),
      linesAdded: _intValue(json['linesAdded']),
      linesRemoved: _intValue(json['linesRemoved']),
      nextBeforeIndex: _intValue(json['nextBeforeIndex']),
      totalCount: _intValue(json['totalCount']),
      isThinking: json['isThinking'] == true,
      statusLabel: json['statusLabel']?.toString(),
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          snapshot.updatedAt,
    );
  }

  String _normalizeNodeId(String from) {
    if (from.startsWith('node:')) return from.substring('node:'.length);
    return from;
  }

  int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  String _projectPathFromNode(NodeState? node) {
    final state = node?.piState;
    final project = state?['project'];
    final candidates = <Object?>[
      state?['projectPath'],
      state?['projectDir'],
      state?['cwd'],
      state?['workingDirectory'],
      state?['workspace'],
      if (project is Map) project['path'],
      if (project is Map) project['dir'],
    ];

    for (final candidate in candidates) {
      final value = candidate?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return 'Current Project';
  }

  String? _sessionIdForNode(String nodeId) {
    final state = _nodes[nodeId]?.piState;
    final sessionId = state?['sessionId']?.toString().trim();
    return sessionId == null || sessionId.isEmpty ? null : sessionId;
  }

  String _projectId(String nodeId, String path) => '$nodeId::$path';

  String _piSessionTaskId(String nodeId, String sessionId) =>
      'pi-session:$nodeId:$sessionId';

  static String _projectName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    if (trimmed.isEmpty) return path;
    return trimmed.split('/').last;
  }

  static String _shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

  @override
  void dispose() {
    _streamingNotifyTimer?.cancel();
    _cursorSaveTimer?.cancel();
    _sessionCacheSaveTimer?.cancel();
    _pendingStreamingTaskNotifications.clear();
    unawaited(_persistCursors());
    unawaited(_persistSessionCache());
    _messageSub.cancel();
    _connectionSub.cancel();
    for (final notifier in _taskNotifiers.values) {
      notifier.dispose();
    }
    _taskNotifiers.clear();
    _recentTasksNotifier.dispose();
    if (_closeSessionCacheOnDispose) {
      unawaited(_sessionCache.close());
    }
    _ws.dispose();
    super.dispose();
  }
}
