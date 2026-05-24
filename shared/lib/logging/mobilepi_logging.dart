import 'dart:convert';

import 'package:logging/logging.dart';

import '../protocol/messages.dart';

const _redacted = '<redacted>';
const _maxValueLength = 160;

final _sensitiveKeyPattern = RegExp(
  r'(^|[_\-.])(token|secret|password|passwd|authorization|cookie|api[_-]?key|access[_-]?key|private[_-]?key)($|[_\-.])',
  caseSensitive: false,
);

String formatLogRecord(LogRecord record) {
  final buffer = StringBuffer()
    ..write(record.time.toUtc().toIso8601String())
    ..write(' ')
    ..write(record.level.name)
    ..write(' ')
    ..write(record.loggerName)
    ..write(' ')
    ..write(record.message);
  if (record.error != null) {
    buffer
      ..write(' error=')
      ..write(_escapeValue(record.error, maxLength: 500));
  }
  if (record.stackTrace != null) {
    buffer
      ..write(' stack=')
      ..write(_escapeValue(record.stackTrace, maxLength: 2000));
  }
  return buffer.toString();
}

String logField(String key, Object? value, {int maxLength = _maxValueLength}) {
  final rendered = _sensitiveKeyPattern.hasMatch(key)
      ? _redacted
      : _escapeValue(value, maxLength: maxLength);
  return '$key=$rendered';
}

String logFields(Map<String, Object?> fields) {
  return fields.entries
      .map((entry) => logField(entry.key, entry.value))
      .join(' ');
}

String shortId(Object? value, {int keep = 8}) {
  final text = value?.toString() ?? '';
  if (text.isEmpty) return '';
  if (text.length <= keep) return text;
  return text.substring(0, keep);
}

String textStats(String key, String? value) {
  final text = value ?? '';
  return '${key}Length=${text.length}';
}

String summarizeMessage(MobilePiMessage message) {
  final payload = message.payload;
  final commandType = payload[ProtocolPayloadKeys.commandType]?.toString();
  final requestId = payload[ProtocolPayloadKeys.requestId]?.toString();
  final taskId = payload['taskId']?.toString();
  final streamId = payload[ProtocolPayloadKeys.streamId]?.toString();
  final fields = <String, Object?>{
    'messageId': shortId(message.messageId),
    'type': message.type.name,
    if (message.kind != null) 'kind': message.kind,
    'from': message.from,
    if (message.to != null) 'to': message.to,
    if (commandType != null && commandType.isNotEmpty) 'command': commandType,
    if (requestId != null && requestId.isNotEmpty)
      'requestId': shortId(requestId),
    if (taskId != null && taskId.isNotEmpty) 'taskId': shortId(taskId),
    if (streamId != null && streamId.isNotEmpty) 'streamId': streamId,
    'payloadKeys': payload.keys.join(','),
  };
  return logFields(fields);
}

String summarizeJsonMessage(Map<String, dynamic> messageJson) {
  final type = messageJson['type']?.toString();
  final payload = messageJson['payload'];
  final payloadKeys = payload is Map ? payload.keys.join(',') : '';
  return logFields({
    'messageId': shortId(messageJson['messageId']),
    if (type != null && type.isNotEmpty) 'type': type,
    if (messageJson['from'] != null) 'from': messageJson['from'],
    if (messageJson['to'] != null) 'to': messageJson['to'],
    if (payloadKeys.isNotEmpty) 'payloadKeys': payloadKeys,
  });
}

String _escapeValue(Object? value, {int maxLength = _maxValueLength}) {
  final raw = value?.toString() ?? 'null';
  final clipped = raw.length > maxLength
      ? '${raw.substring(0, maxLength)}...'
      : raw;
  return jsonEncode(clipped);
}
