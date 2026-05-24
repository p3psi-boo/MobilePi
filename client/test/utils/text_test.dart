import 'package:flutter_test/flutter_test.dart';
import 'package:mobilepi_client/utils/text.dart';

void main() {
  group('agent markup text helpers', () {
    test('closes an unfinished thinking block for display parsing', () {
      expect(
        closeOpenThinkingTag('<thinking>\nreasoning in progress'),
        equals('<thinking>\nreasoning in progress\n</thinking>'),
      );
    });

    test('does not alter already closed thinking blocks', () {
      const text = '<thinking>\nreasoning\n</thinking>\nfinal answer';

      expect(closeOpenThinkingTag(text), equals(text));
    });

    test('stripTags removes unfinished thinking content from previews', () {
      expect(
        stripTags('visible\n<thinking>\nreasoning in progress'),
        equals('visible'),
      );
    });
  });
}
