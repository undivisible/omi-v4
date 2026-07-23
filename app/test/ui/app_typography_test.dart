import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/main.dart';
import 'package:omi/ui/omi_typography.dart';

void main() {
  testWidgets('every app theme sets Inter on every text role', (tester) async {
    await tester.pumpWidget(
      const OmiApp(platformOverride: TargetPlatform.macOS),
    );
    await tester.pump();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    for (final theme in [app.theme, app.darkTheme]) {
      expect(theme, isNotNull);
      final text = theme!.textTheme;
      for (final style in [
        text.displaySmall,
        text.headlineMedium,
        text.titleMedium,
        text.bodyLarge,
        text.bodyMedium,
        text.labelLarge,
      ]) {
        expect(style?.fontFamily, OmiFonts.sans);
      }
    }
  });

  testWidgets('body text under the app theme renders in Inter', (tester) async {
    await tester.pumpWidget(
      const OmiApp(platformOverride: TargetPlatform.macOS),
    );
    await tester.pump();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    for (final theme in [app.theme!, app.darkTheme!]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(body: Text('resolved body copy')),
        ),
      );
      final style = tester
          .widget<RichText>(
            find.descendant(
              of: find.text('resolved body copy'),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style;
      expect(style?.fontFamily, OmiFonts.sans);
    }
  });
}
