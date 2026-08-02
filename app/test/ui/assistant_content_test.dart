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
  bool streaming = false,
}) => MaterialApp(
  home: Scaffold(
    body: AssistantContent(
      text,
      streaming: streaming,
      onPrompt: onPrompt ?? (_) {},
      onDraftPrompt: onDraft ?? (_) {},
      palette: _palette,
    ),
  ),
);

void main() {
  _chartStripping();
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
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('crepus_compute_confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('crepus_compute_confirm_action')));
      await tester.pumpAndSettle();
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

  testWidgets('streaming crepus shows skeleton instead of raw source', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        'Here is what is happening:\n\n'
        '```crepus\n'
        'stack col gap-2\n'
        '  badge "Live Activity"\n'
        '  list\n'
        '    listitem "Still streaming"',
        streaming: true,
      ),
    );
    expect(
      find.byKey(const Key('assistant_crepus_artifact_skeleton')),
      findsOneWidget,
    );
    expect(find.byType(CrepusView), findsNothing);
    expect(find.text('Live Activity'), findsNothing);
    expect(find.byType(AssistantMarkdown), findsOneWidget);
  });

  testWidgets('completed crepus fades in after streaming ends', (tester) async {
    await tester.pumpWidget(
      _host(
        '```crepus\n'
        'stack col gap-2\n'
        '  badge "Live Activity"\n'
        '  text "Ready"\n'
        '```',
        streaming: false,
      ),
    );
    expect(
      find.byKey(const Key('assistant_crepus_artifact_skeleton')),
      findsNothing,
    );
    expect(find.byType(CrepusView), findsOneWidget);
    expect(find.text('Live Activity'), findsOneWidget);
  });

  testWidgets(
    'listitem inline text in artifact renders without empty bullets',
    (tester) async {
      await tester.pumpWidget(
        _host(
          'Here is your profile:\n\n'
          '```crepus\n'
          'stack col gap-2\n'
          '  text "Recent Context & Email Activity"\n'
          '  list\n'
          '    listitem "Mar 12 — Sam asked about the Q2 roadmap"\n'
          '    listitem "Mar 10 — Invoice reminder from Acme"\n'
          '    listitem "Mar 8 — Calendar invite for design review"\n'
          '```',
        ),
      );
      expect(
        find.text('Mar 12 — Sam asked about the Q2 roadmap'),
        findsOneWidget,
      );
      expect(find.text('Mar 10 — Invoice reminder from Acme'), findsOneWidget);
      expect(find.text('•'), findsNWidgets(3));
    },
  );
}

void _chartStripping() {
  group('unsourced charts', () {
    test('drops a chart the model invented, and its nested lines', () {
      expect(
        stripUnsourcedCharts(
          'stack col gap-2\n'
          '  text "Current Focus"\n'
          '  sparkline color=blue variant=gradient values=6,8,7,11\n'
          '    text "legend"\n'
          '  text "keep me"',
        ),
        'stack col gap-2\n  text "Current Focus"\n  text "keep me"',
      );
      for (final element in [
        'chart',
        'linechart',
        'line-chart',
        'barchart',
        'bar-chart',
        'areachart',
        'area-chart',
        'graph',
        'plot',
        'series',
      ]) {
        expect(
          stripUnsourcedCharts('stack col\n  $element values=1,2,3'),
          'stack col',
          reason: element,
        );
      }
    });

    test('keeps a chart whose values came from a tool result', () {
      for (final line in [
        'sparkline values=1,2,3 source=tool:memory_search',
        'sparkline values=1,2,3 source="tool:memory_search"',
        'sparkline values=1,2,3 source={tool:memory_search}',
        'sparkline values=1,2,3 source=TOOL:memory_search',
      ]) {
        expect(chartValuesAreSourced(line), isTrue, reason: line);
        expect(stripUnsourcedCharts(line), line, reason: line);
      }
      for (final line in [
        'sparkline values=1,2,3',
        'sparkline values=1,2,3 source=',
        'sparkline values=1,2,3 source=tool:',
        'sparkline values=1,2,3 datasource=tool:memory_search',
      ]) {
        expect(chartValuesAreSourced(line), isFalse, reason: line);
      }
    });
  });

  testWidgets('an invented chart never reaches the card', (tester) async {
    await tester.pumpWidget(
      _host(
        'Here is where things stand.\n\n'
        '```crepus\n'
        'stack col gap-2\n'
        '  text "Current Focus & Project Load"\n'
        '  sparkline color=blue variant=gradient values=3,5,4,9,11\n'
        '```',
      ),
    );
    expect(find.byKey(const Key('assistant_crepus_artifact')), findsOneWidget);
    expect(find.text('Current Focus & Project Load'), findsOneWidget);
  });

  testWidgets('a chart-only artifact renders nothing at all', (tester) async {
    await tester.pumpWidget(
      _host(
        'Here is where things stand.\n\n'
        '```crepus\n'
        'sparkline color=blue values=3,5,4,9,11\n'
        '```',
      ),
    );
    expect(find.byKey(const Key('assistant_crepus_artifact')), findsNothing);
    expect(find.textContaining('sparkline'), findsNothing);
  });
}
