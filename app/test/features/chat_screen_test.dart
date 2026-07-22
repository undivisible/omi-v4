import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/chat_screen.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/onboarding/hub_checklist.dart';

void main() {
  testWidgets('Set up Omi. renders as a crossed-out completed first row', (
    tester,
  ) async {
    final services = AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    addTearDown(services.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            services: services,
            previewMode: true,
            checklistStore: VolatileHubChecklistStore(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('task_setup_omi')), findsOneWidget);
    final title = tester.widget<Text>(find.text('Set up Omi.'));
    expect(title.style?.decoration, TextDecoration.lineThrough);
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.text('Set up Omi.'),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(opacity.opacity, closeTo(.45, .001));

    await tester.tap(find.byKey(const Key('complete_setup_omi')));
    await tester.pump();
    expect(
      tester.widget<Text>(find.text('Set up Omi.')).style?.decoration,
      TextDecoration.none,
    );
  });

  testWidgets('currents rows show a source tag for conversation evidence', (
    tester,
  ) async {
    final createdAt = DateTime.utc(2026, 7, 21, 12);
    final services = AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      currentsClient: CurrentsClient(_Transport()),
    );
    addTearDown(services.dispose);
    final seeded = <CurrentCard>[
      CurrentCard(
        item: CurrentItem.candidate(
          id: 'meeting-follow-up',
          evidence: [
            CurrentEvidence(sourceId: 'zkr:meeting', reason: 'Commitment'),
          ],
          reason: 'Commitment',
          timing: CurrentTiming(surfaceAt: createdAt),
          confidence: .9,
          proposedNextStep: 'Send the notes',
          createdAt: createdAt,
        ).transitionTo(CurrentStatus.surfaced, at: createdAt),
        title: 'Send the notes',
        summary: 'Send the notes',
        sourceKind: 'conversation',
      ),
    ];
    services.currents!.items = seeded;

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
    services.currents!.items = seeded;
    await tester.pump();

    expect(find.byKey(const Key('task_meeting-follow-up')), findsOneWidget);
    expect(find.text('CONVERSATION'), findsOneWidget);
  });

  testWidgets('task rows render from currents and dismiss on complete tap', (
    tester,
  ) async {
    final currents = CurrentsController(CurrentsClient(_Transport()));
    final createdAt = DateTime.utc(2026, 7, 21, 12);
    CurrentCard current(String id, String title) => CurrentCard(
      item: CurrentItem.candidate(
        id: id,
        evidence: [
          CurrentEvidence(sourceId: 'memory-$id', reason: 'Commitment'),
        ],
        reason: 'Commitment',
        timing: CurrentTiming(surfaceAt: createdAt),
        confidence: .9,
        proposedNextStep: title,
        createdAt: createdAt,
      ).transitionTo(CurrentStatus.surfaced, at: createdAt),
      title: title,
      summary: title,
    );
    currents.items = [
      current('first', 'Finish the release'),
      current('second', 'Reply to Alex'),
    ];

    final services = AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      currentsClient: CurrentsClient(_Transport()),
    );
    addTearDown(services.dispose);
    // Swap in the pre-populated controller so the test controls its items
    // without depending on a network load.
    services.currents!.items = currents.items;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatScreen(services: services)),
      ),
    );
    await tester.pump();
    // Re-seed after the screen's own currents.load() call, whose fake
    // generate/list responses don't match the seeded items.
    services.currents!.items = currents.items;
    await tester.pump();

    expect(find.byKey(const Key('task_first')), findsOneWidget);
    expect(find.byKey(const Key('task_second')), findsOneWidget);
    expect(find.text('Finish the release'), findsOneWidget);
    expect(find.text('Reply to Alex'), findsOneWidget);

    await tester.tap(find.byKey(const Key('complete_first')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('task_first')), findsNothing);
    expect(find.byKey(const Key('task_second')), findsOneWidget);
  });

  // Full hint rotation only kicks in once chatReady is true, which requires
  // a fully wired native/auth stack not easily faked here. This checks the
  // static, not-connected hint that replaced the old prompt ActionChips.
  testWidgets(
    'chat input shows the not-connected hint when chat is not ready',
    (tester) async {
      final services = AppServices.forTesting(
        nativeHub: const UnavailableNativeHub('test'),
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        auth: AuthController(const UnconfiguredAuthGateway()),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      );
      addTearDown(services.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatScreen(services: services, previewMode: true),
          ),
        ),
      );
      await tester.pump();

      TextField input() =>
          tester.widget<TextField>(find.byKey(const Key('chat_input')));

      // previewMode means chatReady is false, so the hint stays the
      // "not connected" copy rather than rotating.
      expect(
        input().decoration!.hintText,
        'Connect an account and model to start chatting',
      );
    },
  );

  testWidgets('meeting events surface progress and a local summary message', (
    tester,
  ) async {
    final auth = AuthController(
      _SignedInGateway(),
      consentStore: VolatileConsentStore()
        ..receipt = ProcessingConsentReceipt.current(
          subjectUid: 'user-meeting',
          acceptedAt: DateTime.utc(2026, 7, 21),
        ),
    );
    await auth.restoreSession();
    final hub = _MeetingEventHub();
    final services = AppServices.forTesting(
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: auth,
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    addTearDown(services.dispose);
    await services.initialize();
    expect(services.chatReady, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatScreen(services: services)),
      ),
    );
    await tester.pump();

    hub.eventsController.add(
      const NativeEventMeetingStateChanged(
        value: MeetingStateChanged(active: true, suggestedTitle: 'Standup'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Meeting detected: Standup'), findsOneWidget);

    hub.eventsController.add(
      const NativeEventMeetingInsight(
        value: MeetingInsight(
          kind: 'action',
          text: 'Capture this commitment',
          sourceText: 'I will send the notes',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Capture this commitment'), findsOneWidget);

    hub.eventsController.add(
      const NativeEventMeetingCompleted(
        value: MeetingCompleted(
          title: 'Standup',
          summary: 'Team agreed to ship Friday.',
          actions: ['Email release notes'],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('Meeting summary: Team agreed to ship Friday.'),
      findsOneWidget,
    );
    expect(find.textContaining('• Email release notes'), findsOneWidget);
  });
}

final class _MeetingEventHub implements NativeHub {
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

final class _SignedInGateway implements AuthGateway {
  final _session = AuthSession(
    uid: 'user-meeting',
    idToken: 'token-user-meeting',
    expiresAt: DateTime.utc(2030),
  );
  final _changes = StreamController<AuthSession?>.broadcast();

  @override
  bool get isConfigured => true;

  @override
  AuthFailure? get configurationFailure => null;

  @override
  bool get supportsPhoneOtp => false;

  @override
  bool get supportsDesktopBrowserHandoff => false;

  @override
  AuthSession? get currentSession => _session;

  @override
  Stream<AuthSession?> get sessionChanges => _changes.stream;

  @override
  Future<AuthSession?> restoreSession() async => _session;

  @override
  Future<AuthSession?> refreshSession() async => _session;

  @override
  Future<void> signOut() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _Transport implements CurrentsTransport {
  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async {
    if (!request.path.endsWith('/feedback')) {
      return const CurrentsResponse(statusCode: 200, body: {});
    }
    final createdAt = DateTime.utc(2026, 7, 21, 12).toIso8601String();
    return CurrentsResponse(
      statusCode: 200,
      body: {
        'current': {
          'id': 'echo',
          'status': 'dismissed',
          'evidence': [
            {'sourceId': 'memory-echo', 'reason': 'Commitment'},
          ],
          'reason': 'Commitment',
          'timing': {'surfaceAt': createdAt},
          'confidence': .9,
          'proposedNextStep': 'echo',
          'createdAt': createdAt,
          'updatedAt': createdAt,
          'title': 'echo',
          'summary': 'echo',
          'feedbackReference': 'feedback-echo',
        },
      },
    );
  }
}
