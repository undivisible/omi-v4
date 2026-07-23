import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/crepus_current.dart';
import 'package:omi/currents/currents.dart';

const _palette = CrepusCurrentPalette(
  ink: Color(0xff171716),
  muted: Color(0xff8d8980),
  hairline: Color(0x1a000000),
  cardBg: Colors.white,
  cardShadow: Color(0x0a000000),
  accent: Color(0xff3139fb),
  rowHover: Color(0x8cffffff),
);

final _now = DateTime(2026, 7, 23, 9);

CurrentCard _card({
  required String id,
  required String title,
  String summary = '',
  double confidence = 0.5,
  DateTime? startsAt,
  DateTime? endsAt,
  String? detail,
  String? crepus,
}) {
  final created = _now.subtract(const Duration(hours: 1));
  final metadata = <String, Object?>{
    if (startsAt != null || detail != null) ...{
      'kind': 'meeting',
      'title': title,
      if (startsAt != null) 'startsAt': startsAt.toIso8601String(),
      if (endsAt != null) 'endsAt': endsAt.toIso8601String(),
      'detail': ?detail,
    },
    'crepus': ?crepus,
  };
  return CurrentCard(
    item: CurrentItem.candidate(
      id: id,
      evidence: [CurrentEvidence(sourceId: 'source-$id', reason: 'because')],
      reason: 'because',
      timing: CurrentTiming(surfaceAt: created),
      confidence: confidence,
      proposedNextStep: 'prep $title',
      createdAt: created,
    ),
    title: title,
    summary: summary,
    metadata: metadata.isEmpty ? null : metadata,
  );
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('planBrief', () {
    test('leads with the soonest unfinished scheduled current', () {
      final plan = planBrief([
        _card(id: 'a', title: 'Loose task', confidence: 0.99),
        _card(
          id: 'b',
          title: 'Later sync',
          startsAt: _now.add(const Duration(hours: 3)),
        ),
        _card(
          id: 'c',
          title: 'Design review',
          startsAt: _now.add(const Duration(minutes: 12)),
        ),
      ], now: _now);
      expect(plan.hero?.card.item.id, 'c');
      expect(plan.rest.map((entry) => entry.card.item.id), ['a', 'b']);
    });

    test('a meeting still running outranks one that already ended', () {
      final plan = planBrief([
        _card(
          id: 'done',
          title: 'Standup',
          startsAt: _now.subtract(const Duration(hours: 2)),
          endsAt: _now.subtract(const Duration(hours: 1)),
        ),
        _card(
          id: 'live',
          title: 'Interview',
          startsAt: _now.subtract(const Duration(minutes: 5)),
          endsAt: _now.add(const Duration(minutes: 25)),
        ),
      ], now: _now);
      expect(plan.hero?.card.item.id, 'live');
    });

    test(
      'falls back to the most confident current when nothing is scheduled',
      () {
        final plan = planBrief([
          _card(id: 'a', title: 'Low', confidence: 0.2),
          _card(id: 'b', title: 'High', confidence: 0.9),
        ], now: _now);
        expect(plan.hero?.card.item.id, 'b');
      },
    );

    test('empty input yields an empty plan', () {
      expect(planBrief(const [], now: _now).isEmpty, isTrue);
    });

    test('rest is capped', () {
      final plan = planBrief([
        for (var index = 0; index < 8; index++)
          _card(id: '$index', title: 'Task $index'),
      ], now: _now);
      expect(plan.rest.length, 3);
    });
  });

  group('briefCountdown', () {
    test('reads at a glance', () {
      expect(briefCountdown(_now, _now), 'Now');
      expect(
        briefCountdown(_now.add(const Duration(minutes: 12)), _now),
        'In 12 min',
      );
      expect(
        briefCountdown(_now.add(const Duration(minutes: 125)), _now),
        'In 2 hr 5 min',
      );
      expect(
        briefCountdown(_now.add(const Duration(hours: 3)), _now),
        'In 3 hr',
      );
      expect(
        briefCountdown(_now.subtract(const Duration(minutes: 5)), _now),
        'Started 5 min ago',
      );
    });
  });

  group('crepusRenders', () {
    test('accepts a supported document', () {
      expect(crepusRenders('stack col gap-2\n  text "Design review"'), isTrue);
    });

    test('rejects blank, unsupported, and oversized documents', () {
      expect(crepusRenders('   '), isFalse);
      expect(crepusRenders('webview src=https://example.com'), isFalse);
      expect(crepusRenders('stack col\n  input bind=secret'), isFalse);
      expect(crepusRenders('text "x"' * 4000), isFalse);
    });
  });

  group('CurrentsBrief', () {
    testWidgets('renders the AI-composed hero when the source is supported', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          CurrentsBrief(
            cards: [
              _card(
                id: 'a',
                title: 'Design review',
                startsAt: _now.add(const Duration(minutes: 12)),
                crepus:
                    'stack col gap-2\n  text text-3xl "Design review"\n  text text-sm "In 12 min"',
              ),
            ],
            palette: _palette,
            now: _now,
            onPrompt: (_) {},
          ),
        ),
      );
      expect(find.text('Design review'), findsOneWidget);
      expect(find.byKey(const Key('brief_hero_title')), findsNothing);
    });

    testWidgets('malformed IR still renders a usable hand-built brief', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          CurrentsBrief(
            cards: [
              _card(
                id: 'a',
                title: 'Design review',
                summary: 'Bring the latest mocks.',
                detail: 'Ana, Bo',
                startsAt: _now.add(const Duration(minutes: 12)),
                endsAt: _now.add(const Duration(minutes: 42)),
                crepus: 'webview src=https://example.com\n  slot',
              ),
            ],
            palette: _palette,
            now: _now,
            onPrompt: (_) {},
          ),
        ),
      );
      expect(find.byKey(const Key('brief_hero_title')), findsOneWidget);
      expect(find.text('Design review'), findsOneWidget);
      expect(find.text('In 12 min'), findsOneWidget);
      expect(find.text('Bring the latest mocks.'), findsOneWidget);
      expect(find.textContaining('Ana, Bo'), findsOneWidget);
    });

    testWidgets('hero actions prompt and complete', (tester) async {
      final prompts = <String>[];
      final completed = <String>[];
      await tester.pumpWidget(
        _host(
          CurrentsBrief(
            cards: [_card(id: 'a', title: 'Reply to Ana')],
            palette: _palette,
            now: _now,
            onPrompt: prompts.add,
            onComplete: completed.add,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('brief_hero_prep')));
      await tester.tap(find.byKey(const Key('brief_hero_done')));
      expect(prompts, ['prep Reply to Ana']);
      expect(completed, ['a']);
    });

    testWidgets('a non-whitelisted action in the composed hero is inert', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          CurrentsBrief(
            cards: [
              _card(
                id: 'a',
                title: 'Design review',
                crepus: 'button "Danger" onclick={exec:rm -rf /}',
              ),
            ],
            palette: _palette,
            now: _now,
            onPrompt: (_) => fail('prompt should not fire'),
            onComplete: (_) => fail('complete should not fire'),
          ),
        ),
      );
      await tester.tap(find.text('Danger'));
      await tester.pump();
    });

    testWidgets('an empty brief is calm, not broken', (tester) async {
      await tester.pumpWidget(
        _host(
          CurrentsBrief(
            cards: const [],
            palette: _palette,
            now: _now,
            onPrompt: (_) {},
          ),
        ),
      );
      expect(find.text('Nothing scheduled'), findsOneWidget);
    });

    testWidgets('secondary currents render under the hero', (tester) async {
      await tester.pumpWidget(
        _host(
          CurrentsBrief(
            cards: [
              _card(
                id: 'a',
                title: 'Design review',
                startsAt: _now.add(const Duration(minutes: 12)),
              ),
              _card(id: 'b', title: 'Reply to Ana', summary: 'She is waiting.'),
            ],
            palette: _palette,
            now: _now,
            onPrompt: (_) {},
          ),
        ),
      );
      expect(find.text('THEN'), findsOneWidget);
      expect(find.byKey(const ValueKey('brief_row_b')), findsOneWidget);
    });
  });
}
