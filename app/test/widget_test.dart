import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/main.dart';

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Future<void> reachPreviewGate(WidgetTester tester) async {
  await tapVisible(tester, find.byKey(const Key('preview_acknowledgement')));
  await tester.pumpAndSettle();
  await tapVisible(tester, find.byKey(const Key('continue_preview_intro')));
  await tester.pumpAndSettle();

  for (final answer in [
    'Alex, building a focused product.',
    'Remember decisions and surface loose ends.',
    'What are my tasks?',
  ]) {
    await tester.enterText(find.byKey(const Key('onboarding_input')), answer);
    await tapVisible(tester, find.byKey(const Key('continue_onboarding')));
    await tester.pumpAndSettle();
  }
}

Future<void> openInterfacePreview(WidgetTester tester) async {
  await reachPreviewGate(tester);
  await tapVisible(tester, find.byKey(const Key('open_interface_preview')));
  await tester.pumpAndSettle();
}

Future<void> openNarrowDestination(WidgetTester tester, int index) async {
  if (index < 3) {
    await tester.tap(find.byKey(ValueKey('narrow_destination_$index')));
  } else {
    await tester.tap(find.byKey(const ValueKey('narrow_more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('narrow_destination_$index')));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('onboarding blocks empty answers and production completion', (
    tester,
  ) async {
    await tester.pumpWidget(const OmiApp());

    expect(find.text('Let’s build your second brain.'), findsOneWidget);
    expect(find.text('INTERFACE PREVIEW'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('continue_preview_intro')))
          .onPressed,
      isNull,
    );

    await tapVisible(tester, find.byKey(const Key('preview_acknowledgement')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('continue_preview_intro')));
    await tester.pumpAndSettle();

    await tapVisible(tester, find.byKey(const Key('continue_onboarding')));
    await tester.pumpAndSettle();
    expect(find.text('Enter an answer before continuing.'), findsOneWidget);
    expect(find.text('PREVIEW QUESTION 1 OF 3'), findsOneWidget);

    for (final answer in [
      'Alex, building a focused product.',
      'Remember decisions and surface loose ends.',
      'What are my tasks?',
    ]) {
      await tester.enterText(find.byKey(const Key('onboarding_input')), answer);
      await tapVisible(tester, find.byKey(const Key('continue_onboarding')));
      await tester.pumpAndSettle();
    }

    expect(find.text('Production setup is not ready.'), findsOneWidget);
    expect(find.text('Accessibility'), findsOneWidget);
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Screen capture'), findsOneWidget);
    expect(find.text('Private app data'), findsOneWidget);
    expect(find.text('Workspace root'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('finish_production_onboarding')),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Chat'), findsNothing);
  });

  testWidgets('explicit demo path opens an honestly disconnected shell', (
    tester,
  ) async {
    await tester.pumpWidget(const OmiApp());
    await openInterfacePreview(tester);

    expect(
      find.textContaining('INTERFACE PREVIEW · Account, memory, AI'),
      findsOneWidget,
    );
    expect(find.text('Chat is not connected yet'), findsOneWidget);
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
        'This phone relays Omi audio through managed or BYOK transcription. Local transcription is not available yet.',
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

  testWidgets('stable memory and channel content is not a live region', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const OmiApp());
    await openInterfacePreview(tester);

    await tester.tap(find.byIcon(Icons.auto_stories_outlined));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(find.text('Memory is not connected'))
          .getSemanticsData()
          .flagsCollection
          .isLiveRegion,
      isFalse,
    );

    await tester.tap(find.byIcon(Icons.checklist_rounded));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(find.text('Connect Telegram'))
          .getSemanticsData()
          .flagsCollection
          .isLiveRegion,
      isFalse,
    );
    semantics.dispose();
  });

  testWidgets('phone preview reaches all surfaces without side effects', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const OmiApp());
    await openInterfacePreview(tester);

    expect(find.byType(NavigationDestination), findsNWidgets(4));
    for (final destination in [
      (0, 'Quietly keeping track, so you can stay in the moment.'),
      (1, 'What Omi knows, with sources you can inspect.'),
      (2, 'Patterns and opportunities moving through your life.'),
      (
        3,
        'This phone relays Omi audio through managed or BYOK transcription. Local transcription is not available yet.',
      ),
      (4, 'Each connection makes your assistant more useful.'),
      (5, 'Identity, plan, providers, and agent control.'),
    ]) {
      await openNarrowDestination(tester, destination.$1);
      expect(find.text(destination.$2), findsOneWidget);
      expect(tester.takeException(), isNull);
    }

    await openNarrowDestination(tester, 3);
    expect(find.text('Device controls unavailable in preview'), findsOneWidget);
    expect(find.byTooltip('Scan'), findsNothing);
    expect(find.byTooltip('Connect'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final surface in [
    (const Size(600, 800), false),
    (const Size(760, 700), true),
    (const Size(1050, 700), true),
  ]) {
    testWidgets(
      'preview navigation is responsive at ${surface.$1.width.toInt()} pixels',
      (tester) async {
        tester.view.physicalSize = surface.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(const OmiApp());
        await openInterfacePreview(tester);

        expect(
          find.byType(NavigationRail),
          surface.$2 ? findsOne : findsNothing,
        );
        expect(
          find.byType(NavigationBar),
          surface.$2 ? findsNothing : findsOne,
        );
        if (surface.$1.width == 1050) {
          expect(
            tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
            isTrue,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('onboarding remains scrollable at short desktop height', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const OmiApp());

    await reachPreviewGate(tester);
    expect(find.text('Production setup is not ready.'), findsOneWidget);
    expect(find.byKey(const Key('open_interface_preview')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview remains usable at 200 percent text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(const OmiApp());
    await openInterfacePreview(tester);

    await openNarrowDestination(tester, 4);
    expect(
      find.text('Each connection makes your assistant more useful.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
