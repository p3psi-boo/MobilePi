import 'package:json_annotation/json_annotation.dart';

part 'messages.g.dart';

/// 消息类型枚举
@JsonEnum()
enum MessageType {
  hello,
  resume,
  command,
  event,
  query,
  response,
  error,
  ping,
  pong,
}

/// Shared payload keys for the direct Client ↔ Node protocol.
///
/// These constants keep additive payload fields aligned across packages while
/// preserving the existing Map-based message envelope.
abstract final class ProtocolPayloadKeys {
  /// User-defined tenant identifier required by Hub during Client/Node hello.
  static const tenantKey = 'tenantKey';

  static const nodeId = 'nodeId';
  static const hostname = 'hostname';
  static const agents = 'agents';

  /// Pi model descriptors returned by Pi RPC get_available_models.
  static const piModels = 'piModels';

  /// Default Pi model path, e.g. "mine/kimi-k2p6-turbo".
  static const piDefaultModel = 'piDefaultModel';

  /// Slash commands registered by Pi extensions and skills.
  static const piSlashCommands = 'piSlashCommands';

  /// Pi instances exposed by this Node; default instance is always present.
  static const piInstances = 'piInstances';

  /// Selected Pi instance for task, steering, follow-up, or panic commands.
  static const piInstanceId = 'piInstanceId';

  /// Current Pi session state returned by Pi RPC get_state.
  static const piState = 'piState';

  /// Current Pi session messages returned by Pi RPC get_messages.
  static const piMessages = 'piMessages';

  /// Optional usage payload attached to a Pi assistant message.
  static const usage = 'usage';

  /// Recent Pi sessions derived from Pi's session manager JSONL files.
  static const piSessions = 'piSessions';

  /// Path to a Pi session file used to resume an existing session.
  static const sessionPath = 'sessionPath';

  /// Node operating system / platform identifier.
  static const platform = 'platform';

  /// Hub-observed daemon connectivity for the current in-memory route.
  static const online = 'online';

  /// Per-task model selection sent by Client to Node.
  static const model = 'model';

  /// Directory path to browse / create / select.
  static const path = 'path';

  /// Parent directory used for a mkdir request.
  static const parentPath = 'parentPath';

  /// Directory name to create under parentPath.
  static const name = 'name';

  /// Subdirectory entries returned by a directory.browse response.
  ///
  /// Each entry is `{ "name": <basename>, "path": <absolute path> }`.
  static const entries = 'entries';

  /// Whether the requested directory is the user's home root.
  static const isHome = 'isHome';

  /// Optional error string returned by browse/create responses.
  static const error = 'error';

  /// Cursor-replay stream id, e.g. `task:<taskId>`.
  static const streamId = 'streamId';

  /// Monotonic sequence number within a stream.
  static const seq = 'seq';

  /// Domain event type, e.g. `task.output.delta`.
  static const eventType = 'type';

  /// Nested domain event payload.
  static const eventPayload = 'payload';

  /// Client-generated idempotency key for command messages.
  static const requestId = 'requestId';

  /// Message id answered by a response or error envelope.
  static const responseTo = 'responseTo';

  /// Per-stream resume cursor map.
  static const cursors = 'cursors';

  /// Batched replay events returned from resume.
  static const events = 'events';

  /// Streams that could not be replayed from the requested cursor.
  static const truncatedStreams = 'truncatedStreams';

  /// Whether a resume response should include the current Node summary.
  static const includeNodeSummary = 'includeNodeSummary';

  /// Current Node summary payload.
  static const nodeSummary = 'nodeSummary';

  /// Hub hello response with currently registered Node summaries.
  static const nodeSummaries = 'nodeSummaries';

  /// Application-level command/query type.
  static const commandType = 'type';

  /// Project path attached to a task create command.
  static const projectPath = 'projectPath';

  /// Human-readable task title.
  static const title = 'title';

  /// Event creation time as an ISO-8601 string.
  static const createdAt = 'createdAt';
}

/// 三端通信消息封装
@JsonSerializable()
class MobilePiMessage {
  final String messageId;
  final String from;
  final String? to;
  final MessageType type;
  final String? kind;
  @JsonKey(defaultValue: 1)
  final int protocolVersion;
  final String? sessionId;
  final Map<String, dynamic> payload;
  final DateTime timestamp;

  MobilePiMessage({
    required this.messageId,
    required this.from,
    this.to,
    required this.type,
    String? kind,
    this.protocolVersion = 1,
    this.sessionId,
    required this.payload,
    DateTime? timestamp,
  }) : kind = kind ?? _protocolKindForType(type),
       timestamp = timestamp ?? DateTime.now().toUtc();

  factory MobilePiMessage.fromJson(Map<String, dynamic> json) =>
      _$MobilePiMessageFromJson(json);
  Map<String, dynamic> toJson() => _$MobilePiMessageToJson(this);

  static String? _protocolKindForType(MessageType type) {
    return switch (type) {
      MessageType.hello => 'hello',
      MessageType.resume => 'resume',
      MessageType.command => 'command',
      MessageType.event => 'event',
      MessageType.query => 'query',
      MessageType.response => 'response',
      MessageType.error => 'error',
      _ => null,
    };
  }
}
