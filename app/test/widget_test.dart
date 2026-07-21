import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/main.dart';

void main() {
  testWidgets('onboarding reaches the assistant shell', (tester) async {
    await tester.pumpWidget(const OmiApp());

    expect(find.text('Let’s build your second brain.'), findsOneWidget);

    for (var step = 0; step < 3; step++) {
      await tester.tap(find.byKey(const Key('continue_onboarding')));
      await tester.pumpAndSettle();
    }

    expect(find.text('Good morning'), findsOneWidget);
    expect(find.byKey(const Key('chat_input')), findsOneWidget);

    for (final destination in [
      (
        Icons.auto_stories_outlined,
        'What Omi knows, with sources you can inspect.',
      ),
      (
        Icons.waves_rounded,
        'Patterns and opportunities moving through your life.',
      ),
      (
        Icons.devices_other_rounded,
        'Capture and control stay visible across every surface.',
      ),
      (
        Icons.checklist_rounded,
        'Each connection makes your assistant more useful.',
      ),
      (
        Icons.person_outline_rounded,
        'Identity, plan, providers, and agent control.',
      ),
    ]) {
      await tester.tap(find.byIcon(destination.$1));
      await tester.pumpAndSettle();
      expect(find.text(destination.$2), findsOneWidget);
    }
  });
}
