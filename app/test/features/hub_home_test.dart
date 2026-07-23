import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/api/dev_gemini.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/chat_screen.dart';
import 'package:omi/features/hub_task_meta.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/onboarding/hub_checklist.dart';

void main() {
  AppServices makeServices({CurrentsClient? currentsClient}) =>
      AppServices.forTesting(
        nativeHub: const UnavailableNativeHub('test'),
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        auth: AuthController(const UnconfiguredAuthGateway()),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        currentsClient: currentsClient,
      );

  group('HubTaskMeta', () {
    test('round-trips through encode and tryDecode', () {
      final meta = HubTaskMeta(
        kind: 'meeting',
        title: 'Design sync',
        startsAt: DateTime.utc(2026, 7, 22, 9, 30),
        endsAt: DateTime.utc(2026, 7, 22, 10, 15),
        detail: 'Review the onboarding flow',
      );
      final decoded = HubTaskMeta.tryDecode(meta.encode());
      expect(decoded, isNotNull);
      expect(decoded!.kind, 'meeting');
      expect(decoded.title, 'Design sync');
      expect(decoded.startsAt, DateTime.utc(2026, 7, 22, 9, 30));
      expect(decoded.endsAt, DateTime.utc(2026, 7, 22, 10, 15));
      expect(decoded.detail, 'Review the onboarding flow');
      expect(decoded.formatTimeRange(), contains('–'));
    });

    test('rejects plain titles and malformed payloads', () {
      expect(HubTaskMeta.tryDecode('Reply to Alex about the notes'), isNull);
      expect(HubTaskMeta.tryDecode('{not json'), isNull);
      expect(HubTaskMeta.tryDecode('{"kind":"meeting"}'), isNull);
      expect(HubTaskMeta.tryDecode('{"kind":"","title":"x"}'), isNull);
    });
  });

  testWidgets('greeter fades out after the first send', (tester) async {
    DevGemini.debugOverride = 'AIzaTestDevKey';
    addTearDown(() => DevGemini.debugOverride = null);
    final services = AppServices.forTesting(
      nativeHub: _EventHub(),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    addTearDown(services.dispose);
    await services.initialize();
    expect(services.localMode, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            services: services,
            checklistStore: VolatileHubChecklistStore(),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('hub_greeter')), findsOneWidget);
    expect(find.byKey(const Key('hub_greeting')), findsOneWidget);
    expect(find.byKey(const Key('history_top_fade')), findsNothing);

    await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
    await tester.tap(find.byKey(const Key('send_chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const Key('hub_greeter')), findsNothing);
    expect(find.byKey(const Key('hub_greeting')), findsNothing);
    expect(find.text('hello'), findsOneWidget);
    expect(find.byKey(const Key('history_top_fade')), findsOneWidget);
  });

  testWidgets('history top fade paints the page background over the tail', (
    tester,
  ) async {
    DevGemini.debugOverride = 'AIzaTestDevKey';
    addTearDown(() => DevGemini.debugOverride = null);
    final services = AppServices.forTesting(
      nativeHub: _EventHub(),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    addTearDown(services.dispose);
    await services.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.light),
        home: Scaffold(
          body: ChatScreen(
            services: services,
            checklistStore: VolatileHubChecklistStore(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byKey(const Key('chat_input')), 'hi there');
    await tester.tap(find.byKey(const Key('send_chat')));
    await tester.pump(const Duration(milliseconds: 600));

    final fade = tester.widget<DecoratedBox>(
      find.byKey(const Key('history_top_fade')),
    );
    final gradient =
        (fade.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors.first, const Color(0xfff7f6f1));
    expect(gradient.colors.last.a, 0);
    final rect = tester.getRect(find.byKey(const Key('history_top_fade')));
    expect(rect.height, 90);
  });

  testWidgets('placeholder text animates between rotating prompts', (
    tester,
  ) async {
    DevGemini.debugOverride = 'AIzaTestDevKey';
    addTearDown(() => DevGemini.debugOverride = null);
    final services = AppServices.forTesting(
      nativeHub: _EventHub(),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    addTearDown(services.dispose);
    await services.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            services: services,
            checklistStore: VolatileHubChecklistStore(),
          ),
        ),
      ),
    );
    await tester.pump();

    final switcherFinder = find.byKey(const Key('chat_placeholder'));
    expect(switcherFinder, findsOneWidget);
    expect(tester.widget(switcherFinder), isA<AnimatedSwitcher>());
    expect(
      find.descendant(
        of: switcherFinder,
        matching: find.text('Turn today’s notes into a plan'),
      ),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 3300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.descendant(
        of: switcherFinder,
        matching: find.text('What should I do next?'),
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(const Key('chat_input')), 'typing');
    await tester.pump();
    expect(find.byKey(const Key('chat_placeholder')), findsNothing);
  });

  testWidgets('tasks with meeting metadata render as rich calendar rows', (
    tester,
  ) async {
    final createdAt = DateTime.utc(2026, 7, 21, 12);
    final services = makeServices(currentsClient: CurrentsClient(_Transport()));
    addTearDown(services.dispose);
    final meta = HubTaskMeta(
      kind: 'meeting',
      title: 'Design sync',
      startsAt: DateTime(2026, 7, 22, 9, 30),
      endsAt: DateTime(2026, 7, 22, 10, 15),
      detail: 'Agenda: onboarding polish',
    );
    final seeded = <CurrentCard>[
      CurrentCard(
        item: CurrentItem.candidate(
          id: 'design-sync',
          evidence: [
            CurrentEvidence(sourceId: 'eventkit:design-sync', reason: 'Event'),
          ],
          reason: 'Event',
          timing: CurrentTiming(surfaceAt: createdAt),
          confidence: .9,
          proposedNextStep: 'Prepare for the design sync',
          createdAt: createdAt,
        ).transitionTo(CurrentStatus.surfaced, at: createdAt),
        title: 'Design sync',
        summary: 'Design sync',
        sourceKind: 'calendar',
        metadata: {
          'kind': 'meeting',
          'title': 'Design sync',
          'startsAt': DateTime(2026, 7, 22, 9, 30).toIso8601String(),
          'endsAt': DateTime(2026, 7, 22, 10, 15).toIso8601String(),
          'detail': 'Agenda: onboarding polish',
        },
      ),
      CurrentCard(
        item: CurrentItem.candidate(
          id: 'plain',
          evidence: [CurrentEvidence(sourceId: 'memory-plain', reason: 'C')],
          reason: 'C',
          timing: CurrentTiming(surfaceAt: createdAt),
          confidence: .9,
          proposedNextStep: 'Reply to Alex about the notes',
          createdAt: createdAt,
        ).transitionTo(CurrentStatus.surfaced, at: createdAt),
        title: 'Reply to Alex about the notes',
        summary: 'Reply to Alex about the notes',
      ),
    ];
    services.currents!.items = seeded;

    final store = VolatileHubChecklistStore()..tasks = [meta.encode()];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(services: services, checklistStore: store),
        ),
      ),
    );
    await tester.pump();
    services.currents!.items = seeded;
    await tester.pump();

    expect(find.byKey(const Key('task_design-sync')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('rich_task_card_Design sync')),
      findsWidgets,
    );
    expect(
      find.byKey(const ValueKey('rich_task_time_Design sync')),
      findsWidgets,
    );
    expect(find.text('9:30 AM – 10:15 AM'), findsWidgets);
    expect(find.text('Agenda: onboarding polish'), findsWidgets);
    expect(find.text('CALENDAR'), findsOneWidget);
    expect(find.text('Reply to Alex about the notes'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('rich_task_card_Reply to Alex about the notes'),
      ),
      findsNothing,
    );
  });
}

final class _EventHub implements NativeHub {
  final eventsController = StreamController<NativeEvent>.broadcast();

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => eventsController.stream;

  @override
  Future<void> initialize() async {}

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _Transport implements CurrentsTransport {
  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async =>
      const CurrentsResponse(statusCode: 200, body: {});
}
