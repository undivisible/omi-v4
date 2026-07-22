import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/ui/omi_ui.dart';

void main() {
  testWidgets('primary variant renders a cream stadium filled button', (
    tester,
  ) async {
    var pressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: OmiButton(
              onPressed: () => pressed = true,
              child: const Text('Continue'),
            ),
          ),
        ),
      ),
    );

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(
      button.style?.backgroundColor?.resolve({}),
      const Color(0xfffffcec),
    );
    expect(
      button.style?.foregroundColor?.resolve({}),
      const Color(0xff171716),
    );
    expect(button.style?.shape?.resolve({}), isA<StadiumBorder>());
    await tester.tap(find.text('Continue'));
    expect(pressed, isTrue);
  });

  testWidgets('secondary variant renders a cream outline button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: OmiButton(
              variant: OmiButtonVariant.secondary,
              onPressed: () {},
              child: const Text('Try again'),
            ),
          ),
        ),
      ),
    );

    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(
      button.style?.foregroundColor?.resolve({}),
      const Color(0xfffffcec),
    );
    expect(button.style?.shape?.resolve({}), isA<StadiumBorder>());
  });

  testWidgets('destructive variant renders red with cream text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: OmiButton(
              variant: OmiButtonVariant.destructive,
              onPressed: () {},
              child: const Text('Delete'),
            ),
          ),
        ),
      ),
    );

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(
      button.style?.backgroundColor?.resolve({}),
      const Color(0xffb42318),
    );
    expect(
      button.style?.foregroundColor?.resolve({}),
      const Color(0xfffffcec),
    );
  });
}
