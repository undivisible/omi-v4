import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/demo/demo_app.dart';
import 'package:omi/demo/demo_currents_transport.dart';
import 'package:omi/demo/demo_native_hub.dart';
import 'package:omi/demo/demo_seed.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/features/omi_shell.dart';
import 'package:omi/features/setup_account_screens.dart';
import 'package:omi/main.dart';
import 'package:omi/native/native_hub.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(demoPreferences()));

  test(
    'the seeded currents survive the real client and its validation',
    () async {
      final client = CurrentsClient(DemoCurrentsTransport());
      await client.generate();
      final cards = await client.list();
      expect(cards, isNotEmpty);
      for (final card in cards) {
        expect(card.title, isNotEmpty);
        expect(card.summary, isNotEmpty);
        expect(card.item.evidence, isNotEmpty);
        expect(card.item.status, CurrentStatus.surfaced);
      }
    },
  );

  test('every cited source resolves inside the seed', () async {
    final cards = await CurrentsClient(DemoCurrentsTransport()).list();
    final known = {for (final item in demoMemory()) item.id};
    for (final card in cards) {
      for (final evidence in card.item.evidence) {
        expect(
          known,
          contains(evidence.sourceId),
          reason: '${card.item.id} cites ${evidence.sourceId}',
        );
      }
    }
  });

  test('dismissing a current removes it from the seeded list', () async {
    final client = CurrentsClient(DemoCurrentsTransport());
    final before = await client.list();
    await client.feedback(before.first.item.id, CurrentStatus.dismissed);
    final after = await client.list();
    expect(after.length, before.length - 1);
  });

  test(
    'the demo hub answers chat without a model and refuses capture',
    () async {
      final hub = DemoNativeHub();
      addTearDown(hub.dispose);
      final reply = hub.events
          .where((event) => event is NativeEventAssistantDelta)
          .cast<NativeEventAssistantDelta>()
          .takeWhile((event) => !event.value.finalSegment)
          .toList();
      hub.sendMessage(requestId: 'r1', text: 'tell me about zkr memory');
      expect((await reply).map((event) => event.value.text).join(), isNotEmpty);
      expect(
        () => hub.capture(
          requestId: 'r2',
          ingestionKey: 'k',
          source: CaptureSource.chat,
          occurredAtMs: 0,
          recordedAtMs: 0,
        ),
        throwsA(isA<NativeHubUnavailable>()),
      );
      expect(
        () => hub.startMeeting(requestId: 'r3'),
        throwsA(isA<NativeHubUnavailable>()),
      );
    },
  );

  test(
    'the demo reaches local mode, so chat is live without an account',
    () async {
      final services = await createDemoServices();
      addTearDown(services.dispose);
      expect(services.localMode, isTrue);
      expect(services.chatReady, isFalse);
    },
  );

  testWidgets('the demo opens on the shell with its banner, never on sign-in', (
    tester,
  ) async {
    final services = await createDemoServices();
    addTearDown(services.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      OmiApp(
        services: services,
        onboardingCompletionStore: demoOnboardingCompletion(),
        platformOverride: TargetPlatform.macOS,
        navigatorKey: navigator,
        overlayBuilder: (context, child) => DemoBanner(
          services: services,
          navigator: navigator,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(OmiShell), findsOneWidget);
    expect(find.byKey(const Key('demo_banner_host')), findsOneWidget);
    expect(find.text('DEMO'), findsOneWidget);
    expect(find.byKey(const Key('demo_open_omi')), findsOneWidget);

    await tester.tap(find.byKey(const Key('demo_open_settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    // The banner survives the route change: it is mounted above the navigator.
    expect(find.text('DEMO'), findsOneWidget);
  });
}
