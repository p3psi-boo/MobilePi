import 'package:mobilepi_shared/mobilepi_shared.dart';

/// Node 在线状态模型
class PiModelInfo {
  final String id;
  final String provider;
  final String model;
  final String name;
  final bool isDefault;
  final bool supportsImages;
  final bool supportsReasoning;
  final int? contextWindow;
  final int? maxTokens;

  const PiModelInfo({
    required this.id,
    required this.provider,
    required this.model,
    required this.name,
    this.isDefault = false,
    this.supportsImages = false,
    this.supportsReasoning = false,
    this.contextWindow,
    this.maxTokens,
  });

  factory PiModelInfo.fromJson(Map<String, dynamic> json) {
    return PiModelInfo(
      id: json['id']?.toString() ?? '',
      provider: json['provider']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      isDefault: json['isDefault'] == true,
      supportsImages: json['supportsImages'] == true,
      supportsReasoning: json['supportsReasoning'] == true,
      contextWindow: json['contextWindow'] as int?,
      maxTokens: json['maxTokens'] as int?,
    );
  }
}

class PiSlashCommandInfo {
  final String name;
  final String description;
  final String source;

  const PiSlashCommandInfo({
    required this.name,
    required this.description,
    required this.source,
  });

  factory PiSlashCommandInfo.fromJson(Map<String, dynamic> json) {
    return PiSlashCommandInfo(
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
    );
  }
}

class PiInstanceInfo {
  final String id;
  final String name;
  final bool isDefault;
  final bool isRunning;
  final String? activeTaskId;
  final String? model;

  const PiInstanceInfo({
    required this.id,
    required this.name,
    this.isDefault = false,
    this.isRunning = false,
    this.activeTaskId,
    this.model,
  });

  factory PiInstanceInfo.fromJson(Map<String, dynamic> json) {
    return PiInstanceInfo(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      isDefault: json['isDefault'] == true,
      isRunning: json['isRunning'] == true,
      activeTaskId: json['activeTaskId']?.toString(),
      model: json['model']?.toString(),
    );
  }
}

class PiSessionInfo {
  final String path;
  final String id;
  final String cwd;
  final String? name;
  final String? parentSessionPath;
  final DateTime? created;
  final DateTime? modified;
  final int messageCount;
  final String firstMessage;
  final List<PiSessionMessageInfo> messages;

  const PiSessionInfo({
    required this.path,
    required this.id,
    required this.cwd,
    this.name,
    this.parentSessionPath,
    this.created,
    this.modified,
    this.messageCount = 0,
    this.firstMessage = '',
    this.messages = const [],
  });

  factory PiSessionInfo.fromJson(Map<String, dynamic> json) {
    return PiSessionInfo(
      path: json['path']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
      cwd: json['cwd']?.toString() ?? '',
      name: json['name']?.toString(),
      parentSessionPath: json['parentSessionPath']?.toString(),
      created: DateTime.tryParse(json['created']?.toString() ?? ''),
      modified: DateTime.tryParse(json['modified']?.toString() ?? ''),
      messageCount: json['messageCount'] is int
          ? json['messageCount'] as int
          : int.tryParse(json['messageCount']?.toString() ?? '') ?? 0,
      firstMessage: json['firstMessage']?.toString() ?? '',
      messages:
          (json['messages'] as List<dynamic>?)
              ?.whereType<Map>()
              .map(
                (e) =>
                    PiSessionMessageInfo.fromJson(Map<String, dynamic>.from(e)),
              )
              .where((message) => message.text.trim().isNotEmpty)
              .toList() ??
          const <PiSessionMessageInfo>[],
    );
  }

  String get displayTitle {
    final title = name?.trim();
    if (title != null && title.isNotEmpty) return title;
    final first = firstMessage.trim();
    if (first.isNotEmpty && first != '(no messages)') return first;
    return 'Pi session ${id.length <= 8 ? id : id.substring(0, 8)}';
  }

  DateTime? get updatedAt => modified ?? created;

  String get transcriptText {
    if (messages.isEmpty) return '';
    return messages.map((message) => message.displayText).join('\n\n');
  }
}

class PiSessionMessageInfo {
  final String role;
  final String text;
  final DateTime? timestamp;
  final String? model;
  final UsageInfo? usage;

  const PiSessionMessageInfo({
    required this.role,
    required this.text,
    this.timestamp,
    this.model,
    this.usage,
  });

  factory PiSessionMessageInfo.fromJson(Map<String, dynamic> json) {
    return PiSessionMessageInfo(
      role: json['role']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? ''),
      model: json['model']?.toString(),
      usage: json['usage'] is Map
          ? UsageInfo.fromJson(Map<String, dynamic>.from(json['usage'] as Map))
          : null,
    );
  }

  String get displayText {
    final label = switch (role) {
      'user' => 'User',
      'assistant' => 'Pi',
      'toolResult' => 'Tool Result',
      _ => role.isEmpty ? 'Message' : role,
    };
    return '$label:\n$text';
  }
}

class NodeState {
  final String nodeId;
  final String hostname;
  final String platform;
  final List<String> agents;
  final List<PiModelInfo> piModels;
  final String? piDefaultModel;
  final List<PiSlashCommandInfo> piSlashCommands;
  final List<PiInstanceInfo> piInstances;
  final Map<String, dynamic>? piState;
  final List<Map<String, dynamic>> piMessages;
  final List<PiSessionInfo> piSessions;
  final bool online;
  final DateTime? lastSeenAt;

  NodeState({
    required this.nodeId,
    required this.hostname,
    this.platform = '',
    required this.agents,
    this.piModels = const [],
    this.piDefaultModel,
    this.piSlashCommands = const [],
    this.piInstances = const [],
    this.piState,
    this.piMessages = const [],
    this.piSessions = const [],
    this.online = false,
    this.lastSeenAt,
  });

  NodeState copyWith({
    String? nodeId,
    String? hostname,
    String? platform,
    List<String>? agents,
    List<PiModelInfo>? piModels,
    String? piDefaultModel,
    List<PiSlashCommandInfo>? piSlashCommands,
    List<PiInstanceInfo>? piInstances,
    Map<String, dynamic>? piState,
    List<Map<String, dynamic>>? piMessages,
    List<PiSessionInfo>? piSessions,
    bool? online,
    DateTime? lastSeenAt,
  }) {
    return NodeState(
      nodeId: nodeId ?? this.nodeId,
      hostname: hostname ?? this.hostname,
      platform: platform ?? this.platform,
      agents: agents ?? this.agents,
      piModels: piModels ?? this.piModels,
      piDefaultModel: piDefaultModel ?? this.piDefaultModel,
      piSlashCommands: piSlashCommands ?? this.piSlashCommands,
      piInstances: piInstances ?? this.piInstances,
      piState: piState ?? this.piState,
      piMessages: piMessages ?? this.piMessages,
      piSessions: piSessions ?? this.piSessions,
      online: online ?? this.online,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }
}
