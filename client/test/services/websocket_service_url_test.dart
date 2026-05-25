import 'package:flutter_test/flutter_test.dart';
import 'package:mobilepi_client/services/websocket_service.dart';

void main() {
  group('WebSocketService.normalizeHubUrl', () {
    test('keeps IPv4 host/path', () {
      expect(
        WebSocketService.normalizeHubUrl('ws://127.0.0.1:8080/ws'),
        'ws://127.0.0.1:8080/ws',
      );
    });

    test('adds /ws when path missing', () {
      expect(
        WebSocketService.normalizeHubUrl('example.com:42040'),
        'ws://example.com:42040/ws',
      );
    });

    test('preserves IPv6 brackets', () {
      expect(
        WebSocketService.normalizeHubUrl(
          'ws://[205:a02b:af52:1080:95:1601:4204:8a51]:42040/ws',
        ),
        'ws://[205:a02b:af52:1080:95:1601:4204:8a51]:42040/ws',
      );
    });
  });
}
