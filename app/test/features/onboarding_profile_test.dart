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
}
