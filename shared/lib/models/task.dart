import 'package:json_annotation/json_annotation.dart';

part 'task.g.dart';

/// 任务状态枚举
@JsonEnum()
enum TaskStatus { idle, running, waitingDecision, error, completed }

/// 看板任务模型
@JsonSerializable()
class Task {
  final String id;
  final String nodeId;
  final String agentType;
  final String title;
  final String description;
  final TaskStatus status;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final int? progressPercent;
  final int? linesAdded;
  final int? linesRemoved;
  final String? screenshotUrl;
  final String? previewUrl;

  Task({
    required this.id,
    required this.nodeId,
    required this.agentType,
    required this.title,
    this.description = '',
    required this.status,
    required this.createdAt,
    this.updatedAt,
    this.progressPercent,
    this.linesAdded,
    this.linesRemoved,
    this.screenshotUrl,
    this.previewUrl,
  });

  factory Task.fromJson(Map<String, dynamic> json) => _$TaskFromJson(json);
  Map<String, dynamic> toJson() => _$TaskToJson(this);

  /// 计算摘要行
  String get summary => linesAdded != null || linesRemoved != null
      ? '+${linesAdded ?? 0} / -${linesRemoved ?? 0} 行'
      : '';
}
