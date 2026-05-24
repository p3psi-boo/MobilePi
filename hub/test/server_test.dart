import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mobilepi_hub/server.dart';
import 'package:mobilepi_shared/mobilepi_shared.dart';
import 'package:test/test.dart';

void main() {
  group('HubServer routing', () {
    late HubServer server;

    setUp(() async {
      server = HubServer(port: 0, tenantKey: 'tenant-a');
      await server.start();
    });

    tearDown(() async {
      await server.shutdown();
    });

    test('client hello returns registered node summaries', () async {
      final daemon = await WebSocket.connect(server.wsUrl);
      final client = await WebSocket.connect(server.wsUrl);
      final clientMessages = StreamIterator<dynamic>(client);
      addTearDown(() async {
        await clientMessages.cancel();
        await daemon.close();
        await client.close();
      });

      daemon.add(
        jsonEncode(
          MobilePiMessage(
            messageId: 'node-hello',
            from: 'node:node-1',
            to: 'hub',
            type: MessageType.hello,
            payload: {
              ProtocolPayloadKeys.tenantKey: 'tenant-a',
              ProtocolPayloadKeys.nodeId: 'node-1',
              ProtocolPayloadKeys.hostname: 'macbook',
              ProtocolPayloadKeys.platform: 'macos',
              ProtocolPayloadKeys.agents: ['pi'],
            },
          ).toJson(),
        ),
      );

      client.add(
        jsonEncode(
          MobilePiMessage(
            messageId: 'client-hello',
            from: 'client',
            to: 'hub',
            type: MessageType.hello,
            payload: const {
              ProtocolPayloadKeys.tenantKey: 'tenant-a',
              'clientId': 'phone-main',
            },
          ).toJson(),
        ),
      );

      expect(await clientMessages.moveNext(), isTrue);
      final response = MobilePiMessage.fromJson(
        jsonDecode(clientMessages.current as String) as Map<String, dynamic>,
      );
      expect(response.type, MessageType.response);
      expect(response.from, 'hub');
      expect(response.to, 'client');
      expect(response.payload[ProtocolPayloadKeys.responseTo], 'client-hello');
      final summaries =
          response.payload[ProtocolPayloadKeys.nodeSummaries] as List;
      expect(summaries.single[ProtocolPayloadKeys.nodeId], 'node-1');
      expect(summaries.single[ProtocolPayloadKeys.online], isTrue);
      expect(
        summaries.single.containsKey(ProtocolPayloadKeys.tenantKey),
        isFalse,
      );
    });

    test('rejects client hello without tenant key', () async {
      final client = await WebSocket.connect(server.wsUrl);
      final clientMessages = StreamIterator<dynamic>(client);
      addTearDown(() async {
        await clientMessages.cancel();
        await client.close();
      });

      client.add(
        jsonEncode(
          MobilePiMessage(
            messageId: 'client-hello',
            from: 'client',
            to: 'hub',
            type: MessageType.hello,
            payload: const {'clientId': 'phone-main'},
          ).toJson(),
        ),
      );

      expect(await clientMessages.moveNext(), isTrue);
      final response = MobilePiMessage.fromJson(
        jsonDecode(clientMessages.current as String) as Map<String, dynamic>,
      );
      expect(response.type, MessageType.error);
      expect(response.payload['code'], 'invalid_tenant_key');
    });

    test('rejects daemon hello with mismatched tenant key', () async {
      final daemon = await WebSocket.connect(server.wsUrl);
      final daemonMessages = StreamIterator<dynamic>(daemon);
      addTearDown(() async {
        await daemonMessages.cancel();
        await daemon.close();
      });

      daemon.add(
        jsonEncode(
          MobilePiMessage(
            messageId: 'node-hello',
            from: 'node:node-1',
            to: 'hub',
            type: MessageType.hello,
            payload: {
              ProtocolPayloadKeys.tenantKey: 'tenant-b',
              ProtocolPayloadKeys.nodeId: 'node-1',
              ProtocolPayloadKeys.hostname: 'macbook',
              ProtocolPayloadKeys.agents: ['pi'],
            },
          ).toJson(),
        ),
      );

      expect(await daemonMessages.moveNext(), isTrue);
      final response = MobilePiMessage.fromJson(
        jsonDecode(daemonMessages.current as String) as Map<String, dynamic>,
      );
      expect(response.type, MessageType.error);
      expect(response.payload['code'], 'invalid_tenant_key');
    });

    test(
      'drops routed messages from peers that have not authenticated',
      () async {
        final client = await WebSocket.connect(server.wsUrl);
        final intruder = await WebSocket.connect(server.wsUrl);
        final clientMessages = StreamIterator<dynamic>(client);
        final intruderMessages = StreamIterator<dynamic>(intruder);
        addTearDown(() async {
          await clientMessages.cancel();
          await intruderMessages.cancel();
          await client.close();
          await intruder.close();
        });

        client.add(
          jsonEncode(
            MobilePiMessage(
              messageId: 'client-hello',
              from: 'client',
              to: 'hub',
              type: MessageType.hello,
              payload: const {
                ProtocolPayloadKeys.tenantKey: 'tenant-a',
                'clientId': 'phone-main',
              },
            ).toJson(),
          ),
        );
        expect(await clientMessages.moveNext(), isTrue);

        intruder.add(
          jsonEncode(
            MobilePiMessage(
              messageId: 'event',
              from: 'node:intruder',
              to: 'client',
              type: MessageType.event,
              payload: const {},
            ).toJson(),
          ),
        );

        expect(await intruderMessages.moveNext(), isTrue);
        final response = MobilePiMessage.fromJson(
          jsonDecode(intruderMessages.current as String)
              as Map<String, dynamic>,
        );
        expect(response.type, MessageType.error);
        expect(response.payload['code'], 'unauthenticated_peer');
      },
    );

    test('routes protocol messages by canonical targets', () async {
      final daemon = await WebSocket.connect(server.wsUrl);
      final client = await WebSocket.connect(server.wsUrl);
      final daemonMessages = StreamIterator<dynamic>(daemon);
      final clientMessages = StreamIterator<dynamic>(client);
      addTearDown(() async {
        await daemonMessages.cancel();
        await clientMessages.cancel();
        await daemon.close();
        await client.close();
      });

      daemon.add(
        jsonEncode(
          MobilePiMessage(
            messageId: 'node-hello',
            from: 'node:node-1',
            to: 'hub',
            type: MessageType.hello,
            payload: {
              ProtocolPayloadKeys.tenantKey: 'tenant-a',
              ProtocolPayloadKeys.nodeId: 'node-1',
              ProtocolPayloadKeys.hostname: 'macbook',
              ProtocolPayloadKeys.agents: ['pi'],
            },
          ).toJson(),
        ),
      );

      client.add(
        jsonEncode(
          MobilePiMessage(
            messageId: 'client-hello',
            from: 'client',
            to: 'hub',
            type: MessageType.hello,
            payload: const {
              ProtocolPayloadKeys.tenantKey: 'tenant-a',
              'clientId': 'phone-main',
            },
          ).toJson(),
        ),
      );
      expect(await clientMessages.moveNext(), isTrue);

      client.add(
        jsonEncode(
          MobilePiMessage(
            messageId: 'cmd',
            from: 'client',
            to: 'node:node-1',
            type: MessageType.command,
            payload: const {
              ProtocolPayloadKeys.commandType: 'task.create',
              ProtocolPayloadKeys.requestId: 'cmd',
              'taskId': 'task-1',
              'prompt': 'run tests',
            },
          ).toJson(),
        ),
      );

      expect(await daemonMessages.moveNext(), isTrue);
      final daemonMessage = MobilePiMessage.fromJson(
        jsonDecode(daemonMessages.current as String) as Map<String, dynamic>,
      );
      expect(daemonMessage.type, MessageType.command);
      expect(daemonMessage.from, 'client');
      expect(daemonMessage.to, 'node:node-1');

      daemon.add(
        jsonEncode(
          MobilePiMessage(
            messageId: 'event',
            from: 'node:node-1',
            to: 'client',
            type: MessageType.event,
            payload: const {
              ProtocolPayloadKeys.streamId: 'task:task-1',
              ProtocolPayloadKeys.seq: 1,
              ProtocolPayloadKeys.eventType: 'task.output.delta',
              ProtocolPayloadKeys.eventPayload: {
                'taskId': 'task-1',
                'text': 'ok',
              },
            },
          ).toJson(),
        ),
      );

      expect(await clientMessages.moveNext(), isTrue);
      final clientMessage = MobilePiMessage.fromJson(
        jsonDecode(clientMessages.current as String) as Map<String, dynamic>,
      );
      expect(clientMessage.type, MessageType.event);
      expect(clientMessage.from, 'node:node-1');
      expect(clientMessage.to, 'client');
    });
  });
}
