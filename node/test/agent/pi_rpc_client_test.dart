import 'dart:io';

import 'package:mobilepi_node/agent/pi_capabilities.dart';
import 'package:mobilepi_node/agent/pi_rpc_client.dart';
import 'package:test/test.dart';

void main() {
  group('StrictJsonLineSplitter', () {
    test(
      'splits only on LF and preserves unicode separators in JSON strings',
      () async {
        final lines = await Stream<String>.fromIterable([
          '{"text":"a\u2028b',
          '\u2029c"}\r\n{"text":"next"}\n',
        ]).transform(const StrictJsonLineSplitter()).toList();

        expect(lines, ['{"text":"a\u2028b\u2029c"}', '{"text":"next"}']);
      },
    );
  });

  group('filterPiStderrForLog', () {
    test('removes OSC 777 terminal notifications', () {
      final chunk = '\x1b]777;notify;π;Hi! ready for input\x07';

      expect(filterPiStderrForLog(chunk), isEmpty);
    });

    test('removes Kitty OSC 99 terminal notifications', () {
      final chunk =
          '\x1b]99;i=1:d=0;Pi\x1b\\'
          '\x1b]99;i=1:p=body;Ready\x1b\\';

      expect(filterPiStderrForLog(chunk), isEmpty);
    });

    test('keeps non-notification stderr around terminal notifications', () {
      final chunk =
          'before\n'
          '\x1b]777;notify;π;Ready\x07'
          'after\n';

      expect(filterPiStderrForLog(chunk), 'before\nafter\n');
    });
  });

  group('PiModelInfo.fromRpcModel', () {
    test('normalizes provider and model fields from RPC model payload', () {
      final model = PiModelInfo.fromRpcModel({
        'provider': 'mine',
        'id': 'kimi-k2p6-turbo',
        'name': 'Kimi K2.6 Turbo',
        'input': ['text', 'image'],
        'reasoning': true,
        'contextWindow': 256000,
      }, currentModelPath: 'mine/kimi-k2p6-turbo');

      expect(model.id, 'mine/kimi-k2p6-turbo');
      expect(model.provider, 'mine');
      expect(model.model, 'kimi-k2p6-turbo');
      expect(model.isDefault, isTrue);
      expect(model.supportsImages, isTrue);
      expect(model.supportsReasoning, isTrue);
      expect(model.contextWindow, 256000);
    });
  });

  group('PiRpcClient Sandboxing', () {
    test('wraps executable and arguments properly based on parameters', () async {
      final isMac = Platform.isMacOS;
      final isLinux = Platform.isLinux;

      if (isMac) {
        final client = PiRpcClient(
          executable: 'pi-nonexistent',
          args: ['--mode', 'rpc'],
          sandboxMode: 'macos',
        );
        try {
          await client.start();
        } catch (e) {
          expect(e.toString(), contains('sandbox-exec'));
        }
      } else if (isLinux) {
        final client = PiRpcClient(
          executable: 'pi-nonexistent',
          args: ['--mode', 'rpc'],
          sandboxMode: 'systemd',
          cpuLimit: '40%',
          memLimit: '1G',
        );
        try {
          await client.start();
        } catch (e) {
          expect(e.toString(), contains('systemd-run'));
        }
      } else {
        final client = PiRpcClient(
          executable: 'pi-invalid',
          args: ['--mode', 'rpc'],
          sandboxMode: 'none',
        );
        try {
          await client.start();
        } catch (e) {
          expect(e.toString(), contains('pi-invalid'));
        }
      }
    });
  });
}
