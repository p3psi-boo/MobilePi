import 'package:flutter_test/flutter_test.dart';
import 'package:mobilepi_client/models/node_state.dart';

void main() {
  group('NodeState', () {
    test('copyWith preserves unchanged fields', () {
      final node = NodeState(
        nodeId: 'node-1',
        hostname: 'macbook',
        agents: const ['codex'],
        online: true,
      );

      final offline = node.copyWith(online: false);

      expect(offline.nodeId, equals('node-1'));
      expect(offline.hostname, equals('macbook'));
      expect(offline.agents, equals(['codex']));
      expect(offline.piModels, isEmpty);
      expect(offline.piSlashCommands, isEmpty);
      expect(offline.piInstances, isEmpty);
      expect(offline.online, isFalse);
    });

    test('parses Pi model, command, and instance descriptors', () {
      final model = PiModelInfo.fromJson({
        'id': 'mine/kimi-k2p6-turbo',
        'provider': 'mine',
        'model': 'kimi-k2p6-turbo',
        'name': 'Kimi K2.6 Turbo',
        'isDefault': true,
        'supportsImages': true,
        'supportsReasoning': true,
        'contextWindow': 256000,
      });
      final command = PiSlashCommandInfo.fromJson({
        'name': 'context',
        'description': 'Show loaded context overview',
        'source': 'extensions/context.ts',
      });
      final instance = PiInstanceInfo.fromJson({
        'id': 'default',
        'name': 'Default Pi',
        'isDefault': true,
        'isRunning': true,
        'activeTaskId': 'task-1',
        'model': 'mine/kimi-k2p6-turbo',
      });

      expect(model.id, equals('mine/kimi-k2p6-turbo'));
      expect(model.isDefault, isTrue);
      expect(model.supportsImages, isTrue);
      expect(model.contextWindow, equals(256000));
      expect(command.name, equals('context'));
      expect(command.source, equals('extensions/context.ts'));
      expect(instance.id, equals('default'));
      expect(instance.isDefault, isTrue);
      expect(instance.isRunning, isTrue);
    });

    test('parses session message usage when present and keeps null when absent', () {
      final withUsage = PiSessionMessageInfo.fromJson({
        'role': 'assistant',
        'text': 'done',
        'usage': {'input_tokens': 10, 'output_tokens': 20, 'total_tokens': 30},
      });
      final withoutUsage = PiSessionMessageInfo.fromJson({
        'role': 'assistant',
        'text': 'done',
      });

      expect(withUsage.usage, isNotNull);
      expect(withUsage.usage!['input_tokens'], equals(10));
      expect(withUsage.usage!['output_tokens'], equals(20));
      expect(withUsage.usage!['total_tokens'], equals(30));
      expect(withoutUsage.usage, isNull);
    });
  });
}
