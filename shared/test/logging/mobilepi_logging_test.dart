import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:test/test.dart';

void main() {
  group('logging helpers', () {
    test('redacts sensitive field names but keeps diagnostic key lists', () {
      final rendered = logFields({
        'apiKey': 'secret-value',
        'payloadKeys': 'type,prompt,requestId',
      });

      expect(rendered, contains('apiKey=<redacted>'));
      expect(rendered, contains('payloadKeys="type,prompt,requestId"'));
      expect(rendered, isNot(contains('secret-value')));
    });

    test('summarizes protocol messages without logging raw prompt text', () {
      final message = MobilePiMessage(
        messageId: 'message-123456789',
        from: 'client',
        to: 'node:node-1',
        type: MessageType.command,
        payload: {
          ProtocolPayloadKeys.commandType: 'task.create',
          ProtocolPayloadKeys.requestId: 'request-123456789',
          'taskId': 'task-123456789',
          'prompt': 'do not log this prompt',
        },
      );

      final summary = summarizeMessage(message);

      expect(summary, contains('messageId="message-"'));
      expect(summary, contains('command="task.create"'));
      expect(summary, contains('requestId="request-"'));
      expect(summary, contains('taskId="task-123"'));
      expect(summary, contains('payloadKeys="type,requestId,taskId,prompt"'));
      expect(summary, isNot(contains('do not log this prompt')));
    });
  });
}
