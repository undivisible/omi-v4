import 'package:crepuscularity_flutter/crepuscularity_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/crepus_current.dart';
import 'package:omi/ui/assistant_content.dart';
import 'package:omi/ui/markdown_text.dart';

const _palette = CrepusCurrentPalette(
  ink: Color(0xff171716),
  muted: Color(0xff8d8980),
  hairline: Color(0x1a000000),
  cardBg: Colors.white,
  cardShadow: Color(0x0a000000),
  accent: Color(0xff3139fb),
  rowHover: Color(0x8cffffff),
);

Widget _host(
  String text, {
  ValueChanged<String>? onPrompt,
  ValueChanged<String>? onDraft,
}) => MaterialApp(
  home: Scaffold(
    body: AssistantContent(
      text,
      onPrompt: onPrompt ?? (_) {},
      onDraftPrompt: onDraft ?? (_) {},
      palette: _palette,
    ),
  ),
);

void main() {
  testWidgets('plain message renders markdown only, no artifact', (
    tester,
  ) async {
    await tester.pumpWidget(_host('Just a plain **answer**.'));
    expect(find.byType(AssistantMarkdown), findsOneWidget);
    expect(find.byType(CrepusView), findsNothing);
    expect(find.byKey(const Key('assistant_crepus_artifact')), findsNothing);
  });

  testWidgets(
    'valid crepus block renders a CrepusView and a button dispatches',
    (tester) async {
      final prompts = <String>[];
      await tester.pumpWidget(
        _host(
          'Here is a plan:\n\n'
          '```crepus\n'
          'stack col gap-2\n'
          '  text "Weekend plan"\n'
          '  button "Find flights" onclick={compute:Search my inbox}\n'
          '```\n\n'
          'Tap to start.',
          onPrompt: prompts.add,
        ),
      );
      expect(find.byType(CrepusView), findsOneWidget);
      expect(
        find.byKey(const Key('assistant_crepus_artifact')),
        findsOneWidget,
      );
      // Surrounding prose still renders as markdown around the artifact.
      expect(find.byType(AssistantMarkdown), findsNWidgets(2));

      await tester.tap(find.text('Find flights'));
      expect(prompts, ['Search my inbox']);
    },
  );

  testWidgets('prompt: button drafts into the composer, never sends', (
    tester,
  ) async {
    final drafts = <String>[];
    await tester.pumpWidget(
      _host(
        '```crepus\n'
        'button "Draft it" onclick={prompt:Write the booking email}\n'
        '```',
        onPrompt: (_) => fail('prompt must not be sent'),
        onDraft: drafts.add,
      ),
    );
    await tester.tap(find.text('Draft it'));
    expect(drafts, ['Write the booking email']);
  });

  testWidgets('invalid crepus block falls back to a code block', (
    tester,
  ) async {
    // `webview` is outside the renderer allowlist, so crepusRenders is false.
    await tester.pumpWidget(
      _host(
        '```crepus\n'
        'webview src=https://example.com\n'
        '```',
      ),
    );
    expect(find.byType(CrepusView), findsNothing);
    expect(find.byKey(const Key('assistant_crepus_artifact')), findsNothing);
    // The raw block is shown as markdown instead of a blank card.
    expect(find.byType(AssistantMarkdown), findsOneWidget);
  });
}
