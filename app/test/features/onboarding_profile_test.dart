import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/onboarding_screen.dart';

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('profile step renders name and language chips with defaults', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        OnboardingProfileStep(
          notice: 'You keep meticulous notes about ferns.',
          defaultName: 'Ada',
          defaultLanguages: const ['English'],
          onContinue: (_, _) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1300));

    expect(find.byKey(const Key('profile_name_chip')), findsOneWidget);
    expect(find.byKey(const Key('profile_languages_chip')), findsOneWidget);
    expect(find.text('You are '), findsOneWidget);
    expect(find.text('. You speak '), findsOneWidget);
    expect(find.textContaining('I think'), findsNothing);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.textContaining('You keep meticulous notes'), findsOneWidget);
  });

  testWidgets('editing the name updates the paragraph', (tester) async {
    await tester.pumpWidget(
      _host(
        OnboardingProfileStep(
          notice: null,
          defaultName: 'there',
          defaultLanguages: const ['English'],
          onContinue: (_, _) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1300));

    await tester.tap(find.byKey(const Key('profile_name_chip')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('profile_name_field')),
      'Grace',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(find.byKey(const Key('profile_name_field')), findsNothing);
    expect(find.text('Grace'), findsOneWidget);
  });

  testWidgets('continue reports the edited name and selected languages', (
    tester,
  ) async {
    String? name;
    List<String>? languages;
    await tester.pumpWidget(
      _host(
        OnboardingProfileStep(
          notice: null,
          defaultName: 'Ada',
          defaultLanguages: const ['English'],
          onContinue: (n, l) {
            name = n;
            languages = l;
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1300));

    await tester.tap(find.byKey(const Key('profile_languages_chip')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('profile_language_French')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('keep_profile')));
    await tester.tap(find.byKey(const Key('keep_profile')));

    expect(name, 'Ada');
    expect(languages, ['English', 'French']);
  });

  group('parseScanSummarySegments', () {
    test('marked names are emphasized and plain text is dimmed', () {
      final segments = parseScanSummarySegments(
        'You are building **omi-v4** with **Rust** daily.',
      );
      expect(segments, hasLength(5));
      expect(segments[0].$1, 'You are building ');
      expect(segments[0].$2, scanSummaryDimmedStyle);
      expect(segments[1].$1, 'omi-v4');
      expect(segments[1].$2, scanSummaryEmphasisStyle);
      expect(segments[3].$1, 'Rust');
      expect(segments[3].$2, scanSummaryEmphasisStyle);
      expect(segments[4].$2, scanSummaryDimmedStyle);
      for (final segment in segments) {
        expect(segment.$1.contains('*'), isFalse);
      }
    });

    test('summaries without markers render at full opacity', () {
      final segments = parseScanSummarySegments('You take notes about ferns.');
      expect(segments, [('You take notes about ferns.', null)]);
    });

    test('unbalanced markers never render literal asterisks', () {
      final single = parseScanSummarySegments('You ship **omi-v4 often.');
      expect(single, [('You ship omi-v4 often.', null)]);
      final segments = parseScanSummarySegments(
        'You ship **omi-v4** with **Rust often.',
      );
      expect(
        segments.map((segment) => segment.$1).join(),
        isNot(contains('*')),
      );
      expect(segments.last.$2, scanSummaryDimmedStyle);
    });

    test('other markdown characters are hard stripped', () {
      final segments = parseScanSummarySegments(
        'You use `cargo` and _tests_ in **omi-v4** # daily',
      );
      final text = segments.map((segment) => segment.$1).join();
      expect(text, isNot(contains('`')));
      expect(text, isNot(contains('_')));
      expect(text, isNot(contains('#')));
      expect(text, contains('cargo'));
      expect(
        segments.singleWhere((segment) => segment.$1 == 'omi-v4').$2,
        scanSummaryEmphasisStyle,
      );
    });

    testWidgets('profile step renders emphasized summary without asterisks', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          OnboardingProfileStep(
            notice: 'You are deep in **omi-v4** this week.',
            defaultName: 'Ada',
            defaultLanguages: const ['English'],
            onContinue: (_, _) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1300));

      expect(find.textContaining('omi-v4'), findsOneWidget);
      expect(find.textContaining('*'), findsNothing);
    });
  });
}
