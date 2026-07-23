import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/crepus_current.dart';

const _palette = CrepusCurrentPalette(
  ink: Color(0xff171716),
  muted: Color(0xff8d8980),
  hairline: Color(0x1a000000),
  cardBg: Colors.white,
  cardShadow: Color(0x0a000000),
  accent: Color(0xff3139fb),
  rowHover: Color(0x8cffffff),
);

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('currentCrepusSource', () {
    test('returns trimmed source when present', () {
      expect(currentCrepusSource({'crepus': '  text "hi"  '}), 'text "hi"');
    });

    test('returns null when absent, blank, or non-string', () {
      expect(currentCrepusSource(null), isNull);
      expect(currentCrepusSource({}), isNull);
      expect(currentCrepusSource({'crepus': '   '}), isNull);
      expect(currentCrepusSource({'crepus': 42}), isNull);
    });
  });

  group('CrepusCurrentRow action whitelist', () {
    testWidgets('complete action fires onComplete', (tester) async {
      var completed = 0;
      await tester.pumpWidget(
        _host(
          CrepusCurrentRow(
            source: 'button "Done" onclick=complete',
            palette: _palette,
            proposedNextStep: 'the next step',
            onComplete: () => completed++,
            onPrompt: (_) => fail('prompt should not fire'),
          ),
        ),
      );
      await tester.tap(find.text('Done'));
      expect(completed, 1);
    });

    testWidgets('prompt:<text> action forwards the text to onPrompt', (
      tester,
    ) async {
      final prompts = <String>[];
      await tester.pumpWidget(
        _host(
          CrepusCurrentRow(
            source: 'button "Go" onclick={prompt:Draft the reply}',
            palette: _palette,
            proposedNextStep: 'the next step',
            onPrompt: prompts.add,
          ),
        ),
      );
      await tester.tap(find.text('Go'));
      expect(prompts, ['Draft the reply']);
    });

    testWidgets('accept action prompts with the proposed next step', (
      tester,
    ) async {
      final prompts = <String>[];
      await tester.pumpWidget(
        _host(
          CrepusCurrentRow(
            source: 'button "Accept" onclick=accept',
            palette: _palette,
            proposedNextStep: 'review the invoice',
            onPrompt: prompts.add,
          ),
        ),
      );
      await tester.tap(find.text('Accept'));
      expect(prompts, ['review the invoice']);
    });

    testWidgets('unrecognised action is inert', (tester) async {
      await tester.pumpWidget(
        _host(
          CrepusCurrentRow(
            source: 'button "Danger" onclick={exec:rm -rf /}',
            palette: _palette,
            proposedNextStep: 'the next step',
            onComplete: () => fail('complete should not fire'),
            onPrompt: (_) => fail('prompt should not fire'),
          ),
        ),
      );
      await tester.tap(find.text('Danger'));
      await tester.pump();
      // No callback fired — the fails above would have thrown otherwise.
    });

    testWidgets('renders the completion affordance only with onComplete', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          CrepusCurrentRow(
            source: 'text "no complete"',
            palette: _palette,
            proposedNextStep: 'x',
            onPrompt: (_) {},
          ),
        ),
      );
      expect(find.byKey(const Key('crepus_current_complete')), findsNothing);
    });
  });
}
