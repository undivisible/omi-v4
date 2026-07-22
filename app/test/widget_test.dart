import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/features/onboarding/backdrop.dart';
import 'package:omi/features/omi_shell.dart';
import 'package:omi/features/setup_account_screens.dart';
import 'package:omi/main.dart';
import 'package:omi/ui/omi_ui.dart';

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(finder);
}

Future<void> reachPreviewGate(WidgetTester tester) async {
  await tapVisible(tester, find.byKey(const Key('continue_preview_intro')));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> openInterfacePreview(WidgetTester tester) async {
  final services = AppServices.fromEnvironment();
  addTearDown(services.dispose);
  await tester.pumpWidget(
    MaterialApp(home: OmiShell(services: services, previewMode: true)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('onboarding copy reveals while the oval mask stays fixed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const OmiApp());

    final intro = find.textContaining('Hi, I’m Omi.');
    final firstFrame = tester.widget<Text>(intro).textSpan! as TextSpan;
    expect((firstFrame.children!.first as TextSpan).style!.color!.a, 0);
    await tester.pump(const Duration(milliseconds: 1200));
    final lastFrame = tester.widget<Text>(intro).textSpan! as TextSpan;
    expect((lastFrame.children!.first as TextSpan).style!.color!.a, 1);

    await tester.pumpWidget(
      const MaterialApp(
        home: OnboardingBackdrop(
          bright: false,
          searching: false,
          settled: false,
          child: SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    final mask = find.byKey(const Key('onboarding_gradient_mask'));
    final originalBounds = tester.getRect(mask);
    expect(find.byType(AnimatedSlide), findsNothing);
    expect(find.byType(AnimatedScale), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: OnboardingBackdrop(
          bright: true,
          searching: true,
          settled: false,
          child: SizedBox.expand(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1800));
    expect(tester.getRect(mask), originalBounds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('onboarding blocks empty answers and production completion', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(const OmiApp());

    expect(find.textContaining('Hi, I’m Omi.'), findsOneWidget);
    expect(
      tester
          .widget<OmiButton>(find.byKey(const Key('continue_preview_intro')))
          .onPressed,
      isNotNull,
    );

    await tapVisible(tester, find.byKey(const Key('continue_preview_intro')));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Before I begin'), findsNothing);
    expect(
      find.text('I would like accessibility access so I can act when you ask.'),
      findsOneWidget,
    );
    expect(
      find.text('I would like to use your microphone so we can talk.'),
      findsOneWidget,
    );
    expect(
      find.text('I would like to see your screen so I can give relevant help.'),
      findsOneWidget,
    );
    expect(
      find.text('I would like Full Disk Access to learn more about you.'),
      findsOneWidget,
    );
    expect(find.textContaining('Firebase'), findsWidgets);
    expect(find.byKey(const Key('grant_processing_consent')), findsNothing);
    expect(find.textContaining('workspace'), findsNothing);
    expect(find.text('Continue'), findsNothing);
    expect(find.text('Chat'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
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
  });

  testWidgets('preview settings route renders without a connected backend', (
    tester,
  ) async {
    final services = AppServices.fromEnvironment();
    addTearDown(services.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(services: services, previewMode: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(
      find.text('Account access is disabled in the interface preview.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final surface in [const Size(600, 800), const Size(1050, 700)]) {
    testWidgets(
      'preview chat surface is responsive at ${surface.width.toInt()} pixels',
      (tester) async {
        tester.view.physicalSize = surface;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(const OmiApp());
        await openInterfacePreview(tester);

        expect(find.byKey(const Key('warm_paper_hub')), findsOneWidget);
        expect(find.byKey(const Key('chat_input')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('onboarding remains scrollable at short desktop height', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const OmiApp());

    await reachPreviewGate(tester);
    expect(
      find.text('I would like to use your microphone so we can talk.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
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

    expect(find.text('Chat is not connected yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
