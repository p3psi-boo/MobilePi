// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'messages.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MobilePiMessage _$MobilePiMessageFromJson(Map<String, dynamic> json) =>
    MobilePiMessage(
      messageId: json['messageId'] as String,
      from: json['from'] as String,
      to: json['to'] as String?,
      type: $enumDecode(_$MessageTypeEnumMap, json['type']),
      kind: json['kind'] as String?,
      protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 1,
      sessionId: json['sessionId'] as String?,
      payload: json['payload'] as Map<String, dynamic>,
      timestamp: json['timestamp'] == null
          ? null
          : DateTime.parse(json['timestamp'] as String),
    );

Map<String, dynamic> _$MobilePiMessageToJson(MobilePiMessage instance) =>
    <String, dynamic>{
      'messageId': instance.messageId,
      'from': instance.from,
      'to': instance.to,
      'type': _$MessageTypeEnumMap[instance.type]!,
      'kind': instance.kind,
      'protocolVersion': instance.protocolVersion,
      'sessionId': instance.sessionId,
      'payload': instance.payload,
      'timestamp': instance.timestamp.toIso8601String(),
    };

const _$MessageTypeEnumMap = {
  MessageType.hello: 'hello',
  MessageType.resume: 'resume',
  MessageType.command: 'command',
  MessageType.event: 'event',
  MessageType.query: 'query',
  MessageType.response: 'response',
  MessageType.error: 'error',
  MessageType.ping: 'ping',
  MessageType.pong: 'pong',
};
