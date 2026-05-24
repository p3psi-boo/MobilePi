// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'task.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Task _$TaskFromJson(Map<String, dynamic> json) => Task(
  id: json['id'] as String,
  nodeId: json['nodeId'] as String,
  agentType: json['agentType'] as String,
  title: json['title'] as String,
  description: json['description'] as String? ?? '',
  status: $enumDecode(_$TaskStatusEnumMap, json['status']),
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: json['updatedAt'] == null
      ? null
      : DateTime.parse(json['updatedAt'] as String),
  progressPercent: (json['progressPercent'] as num?)?.toInt(),
  linesAdded: (json['linesAdded'] as num?)?.toInt(),
  linesRemoved: (json['linesRemoved'] as num?)?.toInt(),
  screenshotUrl: json['screenshotUrl'] as String?,
  previewUrl: json['previewUrl'] as String?,
);

Map<String, dynamic> _$TaskToJson(Task instance) => <String, dynamic>{
  'id': instance.id,
  'nodeId': instance.nodeId,
  'agentType': instance.agentType,
  'title': instance.title,
  'description': instance.description,
  'status': _$TaskStatusEnumMap[instance.status]!,
  'createdAt': instance.createdAt.toIso8601String(),
  'updatedAt': instance.updatedAt?.toIso8601String(),
  'progressPercent': instance.progressPercent,
  'linesAdded': instance.linesAdded,
  'linesRemoved': instance.linesRemoved,
  'screenshotUrl': instance.screenshotUrl,
  'previewUrl': instance.previewUrl,
};

const _$TaskStatusEnumMap = {
  TaskStatus.idle: 'idle',
  TaskStatus.running: 'running',
  TaskStatus.waitingDecision: 'waitingDecision',
  TaskStatus.error: 'error',
  TaskStatus.completed: 'completed',
};
