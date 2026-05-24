class PiCapabilities {
  final String? defaultModel;
  final List<PiModelInfo> models;
  final List<PiSlashCommandInfo> slashCommands;
  final Map<String, dynamic>? state;
  final List<Map<String, dynamic>> messages;
  final List<PiSessionInfo> sessions;

  const PiCapabilities({
    required this.defaultModel,
    required this.models,
    required this.slashCommands,
    this.state,
    this.messages = const [],
    this.sessions = const [],
  });

  static const empty = PiCapabilities(
    defaultModel: null,
    models: <PiModelInfo>[],
    slashCommands: <PiSlashCommandInfo>[],
  );

  Map<String, dynamic> toJson() => {
    if (defaultModel != null) 'defaultModel': defaultModel,
    'models': models.map((m) => m.toJson()).toList(),
    'slashCommands': slashCommands.map((c) => c.toJson()).toList(),
    if (state != null) 'state': state,
    'messages': messages,
    'sessions': sessions.map((s) => s.toJson()).toList(),
  };
}

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
    required this.isDefault,
    required this.supportsImages,
    required this.supportsReasoning,
    this.contextWindow,
    this.maxTokens,
  });

  factory PiModelInfo.fromRpcModel(
    Map<String, dynamic> modelJson, {
    String? currentModelPath,
  }) {
    final rawId =
        modelJson['id']?.toString() ??
        modelJson['model']?.toString() ??
        modelJson['modelId']?.toString() ??
        '';
    var provider =
        modelJson['provider']?.toString() ??
        modelJson['providerId']?.toString() ??
        modelJson['providerName']?.toString() ??
        '';
    var model = rawId;
    if (provider.isEmpty && rawId.contains('/')) {
      final parts = rawId.split('/');
      provider = parts.first;
      model = parts.sublist(1).join('/');
    }
    final path = provider.isEmpty ? model : '$provider/$model';
    final input = modelJson['input'];

    return PiModelInfo(
      id: path,
      provider: provider,
      model: model,
      name:
          modelJson['name']?.toString() ??
          modelJson['displayName']?.toString() ??
          model,
      isDefault: currentModelPath != null && path == currentModelPath,
      supportsImages: input is List && input.contains('image'),
      supportsReasoning:
          modelJson['reasoning'] == true ||
          modelJson['supportsReasoningEffort'] == true ||
          modelJson['thinkingEnabled'] == true,
      contextWindow: _intOrNull(
        modelJson['contextWindow'] ?? modelJson['context_window'],
      ),
      maxTokens: _intOrNull(modelJson['maxTokens'] ?? modelJson['max_tokens']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'provider': provider,
    'model': model,
    'name': name,
    'isDefault': isDefault,
    'supportsImages': supportsImages,
    'supportsReasoning': supportsReasoning,
    if (contextWindow != null) 'contextWindow': contextWindow,
    if (maxTokens != null) 'maxTokens': maxTokens,
  };
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

  factory PiSlashCommandInfo.fromRpcCommand(Map<String, dynamic> commandJson) {
    return PiSlashCommandInfo(
      name: commandJson['name']?.toString() ?? '',
      description: commandJson['description']?.toString() ?? '',
      source:
          commandJson['source']?.toString() ??
          commandJson['sourceInfo']?.toString() ??
          '',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'source': source,
  };
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
    required this.isDefault,
    required this.isRunning,
    this.activeTaskId,
    this.model,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'isDefault': isDefault,
    'isRunning': isRunning,
    if (activeTaskId != null) 'activeTaskId': activeTaskId,
    if (model != null) 'model': model,
  };
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
    required this.messageCount,
    required this.firstMessage,
    this.messages = const [],
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'id': id,
    'cwd': cwd,
    if (name != null) 'name': name,
    if (parentSessionPath != null) 'parentSessionPath': parentSessionPath,
    if (created != null) 'created': created!.toUtc().toIso8601String(),
    if (modified != null) 'modified': modified!.toUtc().toIso8601String(),
    'messageCount': messageCount,
    'firstMessage': firstMessage,
    'messages': messages.map((m) => m.toJson()).toList(),
  };
}

class PiSessionMessageInfo {
  final String role;
  final String text;
  final DateTime? timestamp;
  final String? model;

  const PiSessionMessageInfo({
    required this.role,
    required this.text,
    this.timestamp,
    this.model,
  });

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    if (timestamp != null) 'timestamp': timestamp!.toUtc().toIso8601String(),
    if (model != null) 'model': model,
  };
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
