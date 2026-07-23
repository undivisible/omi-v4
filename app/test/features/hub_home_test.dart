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
    expect(
      find.descendant(
        of: switcherFinder,
        matching: find.text('Turn today’s notes into a plan'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: switcherFinder, matching: find.byType(Text)),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 3300));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.descendant(of: switcherFinder, matching: find.byType(Text)),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.descendant(
        of: switcherFinder,
        matching: find.text('What should I do next?'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: switcherFinder, matching: find.byType(Text)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: switcherFinder,
        matching: find.text('Turn today’s notes into a plan'),
      ),
      findsNothing,
    );

    await tester.enterText(find.byKey(const Key('chat_input')), 'typing');
    await tester.pump();
    expect(find.byKey(const Key('chat_placeholder')), findsNothing);
  });

  AppServices makeLocalServices() {
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
    return services;
  }

  Future<AppServices> pumpLocalHub(
    WidgetTester tester,
    VolatileHubChecklistStore store,
  ) async {
    DevGemini.debugOverride = 'AIzaTestDevKey';
    addTearDown(() => DevGemini.debugOverride = null);
    final services = makeLocalServices();
    await services.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(services: services, checklistStore: store),
        ),
      ),
    );
    await tester.pump();
    return services;
  }

  testWidgets('starter task row tap sends the title as a chat message', (
    tester,
  ) async {
    final store = VolatileHubChecklistStore()..tasks = ['Pick omi back up'];
    await pumpLocalHub(tester, store);
    expect(find.text('Pick omi back up'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('starter_task_Pick omi back up')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const Key('hub_greeter')), findsNothing);
    expect(find.text('Pick omi back up'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('chat_input')))
          .controller!
          .text,
      isEmpty,
    );
    expect(store.doneTasks, isEmpty);
  });

  testWidgets('starter task checkbox completes without sending', (
    tester,
  ) async {
    final store = VolatileHubChecklistStore()..tasks = ['Pick omi back up'];
    await pumpLocalHub(tester, store);

    await tester.tap(
      find.byKey(const ValueKey('complete_starter_Pick omi back up')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.byKey(const Key('hub_greeter')), findsOneWidget);
    expect(store.doneTasks, ['Pick omi back up']);
    expect(store.tasks, ['Pick omi back up']);
  });

  testWidgets('completed starter tasks are restored from the store', (
    tester,
  ) async {
    final store = VolatileHubChecklistStore()
      ..tasks = ['Pick omi back up', 'Decide next step for tsc.hk']
      ..doneTasks = ['Pick omi back up'];
    await pumpLocalHub(tester, store);

    final doneRow = find.descendant(
      of: find.byKey(const ValueKey('starter_task_Pick omi back up')),
      matching: find.text('✓'),
    );
    expect(doneRow, findsOneWidget);
    final pendingRow = find.descendant(
      of: find.byKey(
        const ValueKey('starter_task_Decide next step for tsc.hk'),
      ),
      matching: find.text('✓'),
    );
    expect(pendingRow, findsNothing);
  });

  testWidgets('back button returns to the greeter and keeps history', (
    tester,
  ) async {
    final store = VolatileHubChecklistStore();
    await pumpLocalHub(tester, store);
    expect(find.byKey(const Key('chat_back')), findsNothing);

    await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
    await tester.tap(find.byKey(const Key('send_chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('hub_greeter')), findsNothing);
    expect(find.byKey(const Key('chat_back')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat_back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('hub_greeter')), findsOneWidget);
    expect(find.byKey(const Key('chat_back')), findsNothing);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('input card glows while the assistant is thinking', (
    tester,
  ) async {
    final store = VolatileHubChecklistStore();
    await pumpLocalHub(tester, store);
    expect(find.byKey(const Key('input_thinking_glow')), findsNothing);

    await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
    await tester.tap(find.byKey(const Key('send_chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const Key('input_thinking_glow')), findsOneWidget);
  });

  testWidgets('hub blur fades and glow stay off under reduced motion', (
    tester,
  ) async {
    DevGemini.debugOverride = 'AIzaTestDevKey';
    addTearDown(() => DevGemini.debugOverride = null);
    final services = makeLocalServices();
    await services.initialize();
    final store = VolatileHubChecklistStore()..tasks = ['Pick omi back up'];
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: ChatScreen(services: services, checklistStore: store),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('hub_greeter_blur_fade')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('complete_starter_Pick omi back up')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('task_complete_fade')), findsNothing);

    await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
    await tester.tap(find.byKey(const Key('send_chat')));
    await tester.pump();
    expect(find.byKey(const Key('input_thinking_glow')), findsNothing);
  });

  testWidgets('greeter entrance blur-fades in and rows fade on completion', (
    tester,
  ) async {
    final store = VolatileHubChecklistStore()..tasks = ['Pick omi back up'];
    await pumpLocalHub(tester, store);
    expect(find.byKey(const Key('hub_greeter_blur_fade')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('complete_starter_Pick omi back up')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('task_complete_fade')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byKey(const Key('task_complete_fade')), findsNothing);
  });

  testWidgets('greeter fades out before the first message reaches full '
      'opacity', (tester) async {
    final store = VolatileHubChecklistStore();
    await pumpLocalHub(tester, store);

    await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
    await tester.tap(find.byKey(const Key('send_chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('hub_greeter')), findsOneWidget);
    final messageFade = find.byWidgetPredicate(
      (widget) =>
          widget.runtimeType.toString() == '_BlurFadeIn' &&
          widget.key.toString().contains('msg_fade_'),
    );
    expect(messageFade, findsOneWidget);
    final opacity = tester.widget<Opacity>(
      find.descendant(of: messageFade, matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, lessThan(.05));

    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const Key('hub_greeter')), findsNothing);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('history is reachable from home and snaps to the latest '
      'message', (tester) async {
    tester.view.physicalSize = const Size(800, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = VolatileHubChecklistStore()
      ..tasks = [
        'Pick omi back up',
        'Decide next step for tsc.hk',
        'Review the desktop handoff',
        'Plan the week',
      ];
    await pumpLocalHub(tester, store);

    await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
    await tester.tap(find.byKey(const Key('send_chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.tap(find.byKey(const Key('chat_back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const Key('hub_greeter')), findsOneWidget);

    final scrollable = find.descendant(
      of: find.byKey(const Key('chat_messages')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));

    await tester.fling(
      find.byKey(const Key('chat_messages')),
      const Offset(0, 120),
      900,
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(position.pixels, greaterThan(48));
    final messageRect = tester.getRect(find.text('hello'));
    expect(messageRect.top, greaterThanOrEqualTo(0));
    expect(messageRect.bottom, lessThanOrEqualTo(500));

    await tester.drag(
      find.byKey(const Key('chat_messages')),
      Offset(0, -(position.pixels - 30)),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(position.pixels, 0);
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
