import 'package:mobilepi_node/daemon.dart';
import 'package:test/test.dart';

void main() {
  group('NodeDaemon.normalizeHubUrl', () {
    test('keeps IPv4 host and explicit path', () {
      expect(
        NodeDaemon.normalizeHubUrl('ws://127.0.0.1:8080/ws'),
        'ws://127.0.0.1:8080/ws',
      );
    });

    test('adds default /ws path when missing', () {
      expect(
        NodeDaemon.normalizeHubUrl('example.com:42040'),
        'ws://example.com:42040/ws',
      );
    });

    test('normalizes https/wss to wss scheme', () {
      expect(
        NodeDaemon.normalizeHubUrl('https://hub.example.com/socket'),
        'wss://hub.example.com/socket',
      );
    });

    test('preserves IPv6 brackets in normalized output', () {
      expect(
        NodeDaemon.normalizeHubUrl(
          'ws://[205:a02b:af52:1080:95:1601:4204:8a51]:42040/ws',
        ),
        'ws://[205:a02b:af52:1080:95:1601:4204:8a51]:42040/ws',
      );
    });
  });
}
