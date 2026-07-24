import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/api/dev_assistant.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/chat_screen.dart';
import 'package:omi/features/hub_task_meta.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/onboarding/hub_checklist.dart';

void main() {
  Rect listRect(WidgetTester tester) =>
      tester.getRect(find.byKey(const Key('chat_messages')));

  /// Built but scrolled past counts as gone: the home view and the older
  /// history stay in the list, they just live above the viewport.
  bool onScreen(WidgetTester tester, Finder finder) {
    if (finder.evaluate().isEmpty) return false;
    return tester.getRect(finder).overlaps(listRect(tester));
  }

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

  testWidgets('sending lifts the greeter out and raises the message', (
    tester,
  ) async {
    debugDevAssistantAccess = const DevAssistantAccess(
      credential: 'AIzaTestDevKey',
      liveModel: 'gemini-test-live',
      missingKeyHint: '',
    );
    addTearDown(() => debugDevAssistantAccess = DevAssistantAccess.none);
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
    // Mid-flight the message is still climbing: it starts below the fold.
    await tester.pump(const Duration(milliseconds: 60));
    final rising = tester.getRect(find.text('hello'));
    expect(rising.top, greaterThan(listRect(tester).top));

    await tester.pump(const Duration(milliseconds: 900));
    expect(onScreen(tester, find.byKey(const Key('hub_greeting'))), isFalse);
    expect(find.text('hello'), findsOneWidget);
    final landed = tester.getRect(find.text('hello'));
    expect(landed.top, lessThan(rising.top));
    expect(landed.top - listRect(tester).top, lessThan(48));
    expect(find.byKey(const Key('history_top_fade')), findsOneWidget);
  });

  testWidgets('reduced motion lands the send with no animation to settle', (
    tester,
  ) async {
    debugDevAssistantAccess = const DevAssistantAccess(
      credential: 'AIzaTestDevKey',
      liveModel: 'gemini-test-live',
      missingKeyHint: '',
    );
    addTearDown(() => debugDevAssistantAccess = DevAssistantAccess.none);
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
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: ChatScreen(
              services: services,
              checklistStore: VolatileHubChecklistStore(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
    await tester.tap(find.byKey(const Key('send_chat')));
    await tester.pump();

    expect(onScreen(tester, find.byKey(const Key('hub_greeting'))), isFalse);
    expect(
      tester.getRect(find.text('hello')).top - listRect(tester).top,
      lessThan(48),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('history top fade paints the page background over the tail', (
    tester,
  ) async {
    debugDevAssistantAccess = const DevAssistantAccess(
      credential: 'AIzaTestDevKey',
      liveModel: 'gemini-test-live',
      missingKeyHint: '',
    );
    addTearDown(() => debugDevAssistantAccess = DevAssistantAccess.none);
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
    expect(rect.height, 36);

    // The home view stops short of the viewport so the newest message stays
    // partly visible above it; without that gap scrolling up looks inert.
    final listRect = tester.getRect(find.byKey(const Key('chat_messages')));
    final greeting = tester.getRect(find.byKey(const Key('hub_greeting')));
    expect(greeting.top, greaterThan(listRect.top));
    expect(listRect.bottom - greeting.bottom, greaterThan(0));
  });

  testWidgets('placeholder text animates between rotating prompts', (
    tester,
  ) async {
    debugDevAssistantAccess = const DevAssistantAccess(
      credential: 'AIzaTestDevKey',
      liveModel: 'gemini-test-live',
      missingKeyHint: '',
    );
    addTearDown(() => debugDevAssistantAccess = DevAssistantAccess.none);
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

  AppServices makeLocalServices({_EventHub? hub}) {
    final services = AppServices.forTesting(
      nativeHub: hub ?? _EventHub(),
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
    VolatileHubChecklistStore store, {
    _EventHub? hub,
  }) async {
    debugDevAssistantAccess = const DevAssistantAccess(
      credential: 'AIzaTestDevKey',
      liveModel: 'gemini-test-live',
      missingKeyHint: '',
    );
    addTearDown(() => debugDevAssistantAccess = DevAssistantAccess.none);
    final services = makeLocalServices(hub: hub);
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
    await tester.pump(const Duration(milliseconds: 900));

    expect(onScreen(tester, find.byKey(const Key('hub_greeting'))), isFalse);
    expect(find.text('Pick omi back up'), findsWidgets);
    expect(onScreen(tester, find.text('Pick omi back up').last), isTrue);
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

    expect(onScreen(tester, find.byKey(const Key('hub_greeting'))), isTrue);
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

  /// The composer glows and the skeleton shimmers for as long as a reply is
  /// pending, so no frame is ever the last one; drain the gesture instead of
  /// settling.
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Sends [text] and lets the whole send transition land.
  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('chat_input')), text);
    await tester.tap(find.byKey(const Key('send_chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
  }

  /// Pulls past the newest message and keeps holding for [hold].
  Future<TestGesture> pullPastNewest(
    WidgetTester tester, {
    required Duration hold,
  }) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('chat_messages'))),
    );
    await gesture.moveBy(const Offset(0, -240));
    await tester.pump();
    for (var elapsed = Duration.zero; elapsed < hold;) {
      await tester.pump(const Duration(milliseconds: 50));
      elapsed += const Duration(milliseconds: 50);
    }
    return gesture;
  }

  testWidgets('pulling past the newest message and holding starts a new '
      'conversation', (tester) async {
    final store = VolatileHubChecklistStore();
    await pumpLocalHub(tester, store);
    await send(tester, 'hello');
    expect(
      find.text('Pull past this message and hold for a new chat'),
      findsOneWidget,
    );

    final gesture = await pullPastNewest(
      tester,
      hold: const Duration(milliseconds: 200),
    );
    // Part way there the bar shows how much of the hold is left.
    expect(find.byKey(const Key('chat_new_chat_progress')), findsOneWidget);
    expect(onScreen(tester, find.byKey(const Key('hub_greeting'))), isFalse);

    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await drain(tester);

    expect(onScreen(tester, find.byKey(const Key('hub_greeting'))), isTrue);
    expect(find.byKey(const Key('chat_new_chat_progress')), findsNothing);
    expect(find.text('Earlier messages are above'), findsOneWidget);
    expect(onScreen(tester, find.text('hello')), isFalse);
  });

  testWidgets('releasing the pull early keeps the conversation', (
    tester,
  ) async {
    final store = VolatileHubChecklistStore();
    await pumpLocalHub(tester, store);
    await send(tester, 'hello');

    final gesture = await pullPastNewest(
      tester,
      hold: const Duration(milliseconds: 200),
    );
    expect(find.byKey(const Key('chat_new_chat_progress')), findsOneWidget);
    await gesture.up();
    await drain(tester);

    expect(find.byKey(const Key('chat_new_chat_progress')), findsNothing);
    expect(
      find.text('Pull past this message and hold for a new chat'),
      findsOneWidget,
    );
    expect(onScreen(tester, find.text('hello')), isTrue);
    expect(onScreen(tester, find.byKey(const Key('hub_greeting'))), isFalse);
  });

  testWidgets('a flick past the newest message never starts a new '
      'conversation', (tester) async {
    final store = VolatileHubChecklistStore();
    await pumpLocalHub(tester, store);
    await send(tester, 'hello');

    await tester.fling(
      find.byKey(const Key('chat_messages')),
      const Offset(0, -300),
      2000,
    );
    await drain(tester);

    expect(find.byKey(const Key('chat_new_chat_progress')), findsNothing);
    expect(onScreen(tester, find.text('hello')), isTrue);
    expect(onScreen(tester, find.byKey(const Key('hub_greeting'))), isFalse);
  });

  testWidgets('scrolling up reaches the greeter before it reaches history', (
    tester,
  ) async {
    final store = VolatileHubChecklistStore();
    await pumpLocalHub(tester, store);
    await send(tester, 'first');
    // The dev key never answers, so retire the pending request before the
    // composer is needed again.
    await tester.tap(find.byKey(const Key('cancel_chat')));
    await tester.pump();

    final gesture = await pullPastNewest(
      tester,
      hold: const Duration(milliseconds: 800),
    );
    await gesture.up();
    await drain(tester);
    await send(tester, 'second');
    expect(onScreen(tester, find.text('second')), isTrue);
    expect(onScreen(tester, find.byKey(const Key('hub_greeting'))), isFalse);
    expect(onScreen(tester, find.text('first')), isFalse);

    // One scroll up out of the live exchange: the home view, not history.
    await tester.drag(
      find.byKey(const Key('chat_messages')),
      const Offset(0, 400),
    );
    await drain(tester);
    final greeting = find.byKey(const Key('hub_greeting'));
    expect(onScreen(tester, greeting), isTrue);
    // The older conversation is only ever a peek at this stop: it lives above
    // the home view, not inside it.
    expect(
      tester.getRect(find.text('first')).bottom,
      lessThan(tester.getRect(greeting).top),
    );

    // Keep going and history is what fills the viewport.
    await tester.drag(
      find.byKey(const Key('chat_messages')),
      const Offset(0, 700),
    );
    await drain(tester);
    expect(onScreen(tester, find.text('first')), isTrue);
  });

  testWidgets('only the newest assistant turn carries the omi mark', (
    tester,
  ) async {
    final hub = _EventHub();
    final store = VolatileHubChecklistStore();
    await pumpLocalHub(tester, store, hub: hub);
    await send(tester, 'hello');

    hub.eventsController.add(
      const NativeEventMeetingCompleted(
        value: MeetingCompleted(
          title: 'Standup',
          summary: 'Standup wrapped',
          actions: ['Send the notes'],
          startedAtMs: 0,
          endedAtMs: 0,
          participants: [],
          keyPoints: [],
          decisions: [],
          noteMarkdown: '',
          metadataJson: '',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // The reply is still coming, so the skeleton is the live turn and the
    // finished assistant row beside it must sit still.
    expect(find.byKey(const Key('chat_skeleton')), findsOneWidget);
    expect(find.textContaining('Standup wrapped'), findsOneWidget);
    expect(find.byKey(const Key('chat_latest_orb')), findsOneWidget);

    await tester.tap(find.byKey(const Key('cancel_chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('chat_skeleton')), findsNothing);
    expect(find.byKey(const Key('chat_latest_orb')), findsOneWidget);
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
    debugDevAssistantAccess = const DevAssistantAccess(
      credential: 'AIzaTestDevKey',
      liveModel: 'gemini-test-live',
      missingKeyHint: '',
    );
    addTearDown(() => debugDevAssistantAccess = DevAssistantAccess.none);
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

  testWidgets('a half scroll out of the exchange snaps to one of the two '
      'stops', (tester) async {
    final store = VolatileHubChecklistStore();
    await pumpLocalHub(tester, store);
    await send(tester, 'hello');

    final scrollable = find.descendant(
      of: find.byKey(const Key('chat_messages')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));

    // A nudge out of the exchange falls back to it rather than stranding the
    // user between the two stops.
    await tester.drag(
      find.byKey(const Key('chat_messages')),
      const Offset(0, 20),
    );
    await drain(tester);
    expect(position.pixels, 0);
    expect(onScreen(tester, find.text('hello')), isTrue);

    // Past the halfway mark it commits to the home view instead.
    await tester.drag(
      find.byKey(const Key('chat_messages')),
      const Offset(0, 120),
    );
    await drain(tester);
    expect(position.pixels, greaterThan(48));
    expect(onScreen(tester, find.byKey(const Key('hub_greeting'))), isTrue);
  });

  /// Snap boundaries of every laid-out history turn, measured the way the
  /// widget measures them: each turn's trailing edge aligned to the reversed
  /// viewport's edge.
  List<double> historyBoundaries(WidgetTester tester) {
    final rows = find.byWidgetPredicate(
      (widget) =>
          widget.runtimeType.toString() == '_BlurFadeIn' &&
          widget.key.toString().contains('msg_fade_'),
    );
    final boundaries = <double>[];
    for (final element in rows.evaluate()) {
      final box = element.renderObject! as RenderBox;
      if (!box.hasSize) continue;
      boundaries.add(
        RenderAbstractViewport.of(box).getOffsetToReveal(box, 1).offset,
      );
    }
    boundaries.sort();
    return boundaries;
  }

  /// Sends four turns, each pushed behind a new conversation so it becomes a
  /// history turn above the home view, then leaves a fresh exchange on screen.
  Future<ScrollPosition> seedHistory(WidgetTester tester) async {
    for (final word in ['alpha', 'bravo', 'charlie', 'delta']) {
      await send(tester, word);
      await tester.tap(find.byKey(const Key('cancel_chat')));
      await tester.pump();
      final gesture = await pullPastNewest(
        tester,
        hold: const Duration(milliseconds: 800),
      );
      await gesture.up();
      await drain(tester);
    }
    await send(tester, 'echo');
    final scrollable = find.descendant(
      of: find.byKey(const Key('chat_messages')),
      matching: find.byType(Scrollable),
    );
    return tester.state<ScrollableState>(scrollable).position;
  }

  testWidgets('a scroll that ends mid-history settles on a message '
      'boundary', (tester) async {
    final store = VolatileHubChecklistStore();
    await pumpLocalHub(tester, store);
    final position = await seedHistory(tester);
    expect(position.maxScrollExtent, greaterThan(0));

    // Reach the top so every history turn is laid out and its boundary can be
    // measured.
    await tester.drag(
      find.byKey(const Key('chat_messages')),
      Offset(0, position.maxScrollExtent),
    );
    await drain(tester);
    final boundaries = historyBoundaries(tester);
    expect(
      boundaries.length,
      greaterThan(2),
      reason: 'need several turns to snap between',
    );

    double nearest(double value) => boundaries
        .map((boundary) => (boundary - value).abs())
        .reduce((a, b) => a < b ? a : b);

    // Aim the scroll at the midpoint between two adjacent turn boundaries —
    // squarely mid-message, no natural rest there.
    boundaries.sort();
    final midway = (boundaries[1] + boundaries[2]) / 2;
    expect(nearest(midway), greaterThan(4), reason: 'midway must be off-grid');

    position.jumpTo(midway);
    // A short user drag to end the gesture where the snap logic can act on it.
    await tester.drag(
      find.byKey(const Key('chat_messages')),
      const Offset(0, 3),
    );
    await drain(tester);

    // It settled on one of the turn boundaries rather than the mid-message
    // offset it was aimed at.
    expect(nearest(position.pixels), lessThan(2));
    expect((position.pixels - midway).abs(), greaterThan(4));
  });

  testWidgets('the home and exchange stops still hold with history above', (
    tester,
  ) async {
    final store = VolatileHubChecklistStore();
    await pumpLocalHub(tester, store);
    final position = await seedHistory(tester);

    // A nudge out of the live exchange falls back to it.
    await tester.drag(
      find.byKey(const Key('chat_messages')),
      const Offset(0, 20),
    );
    await drain(tester);
    expect(position.pixels, 0);
    expect(onScreen(tester, find.text('echo')), isTrue);

    // Past the commit point it settles on the home view above the exchange.
    await tester.drag(
      find.byKey(const Key('chat_messages')),
      const Offset(0, 120),
    );
    await drain(tester);
    expect(position.pixels, greaterThan(48));
    expect(onScreen(tester, find.byKey(const Key('hub_greeting'))), isTrue);
  });

  testWidgets('history snapping leaves the new-chat pull untouched', (
    tester,
  ) async {
    final store = VolatileHubChecklistStore();
    await pumpLocalHub(tester, store);
    await seedHistory(tester);

    // The pull-and-hold past the newest message still starts a new chat; the
    // snap logic never fires during the pull and never fights it.
    final gesture = await pullPastNewest(
      tester,
      hold: const Duration(milliseconds: 200),
    );
    expect(find.byKey(const Key('chat_new_chat_progress')), findsOneWidget);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await drain(tester);

    expect(onScreen(tester, find.byKey(const Key('hub_greeting'))), isTrue);
    expect(onScreen(tester, find.text('echo')), isFalse);
    expect(find.text('Earlier messages are above'), findsOneWidget);
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
