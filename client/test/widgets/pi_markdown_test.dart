import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilepi_client/widgets/pi_markdown.dart';

void main() {
  tearDown(PiMarkdown.debugClearCache);

  testWidgets('caches rendered markdown across widget lifetimes', (
    tester,
  ) async {
    PiMarkdown.debugClearCache();

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PiMarkdown('hello **world**'))),
    );
    expect(PiMarkdown.debugCacheSize, 1);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    expect(PiMarkdown.debugCacheSize, 1);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PiMarkdown('hello **world**'))),
    );
    expect(PiMarkdown.debugCacheSize, 1);
  });

  testWidgets('bounds markdown render cache size', (tester) async {
    PiMarkdown.debugClearCache();

    for (var i = 0; i < 120; i++) {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PiMarkdown('message $i'))),
      );
    }

    expect(PiMarkdown.debugCacheSize, 96);
  });
}
