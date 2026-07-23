import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/meeting_assist_panel.dart';
import 'package:omi/native/generated/signals/signals.dart' show NativeError;
import 'package:omi/native/native_hub.dart';

void main() {
  Future<(AppServices, _RecordingMeetingHub)> servicesWithHub() async {
    final auth = AuthController(
      _SignedInGateway(),
      consentStore: VolatileConsentStore()
        ..receipt = ProcessingConsentReceipt.current(
          subjectUid: 'user-panel',
          acceptedAt: DateTime.utc(2026, 7, 21),
        ),
    );
    await auth.restoreSession();
    final hub = _RecordingMeetingHub();
    final services = AppServices.forTesting(
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: auth,
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();
    return (services, hub);
  }

  testWidgets('panel stays hidden until a meeting starts and then assists', (
    tester,
  ) async {
    final (services, hub) = await servicesWithHub();
    addTearDown(services.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MeetingAssistPanel(services: services)),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('meeting_assist_panel')), findsNothing);

    hub.eventsController.add(
      const NativeEventMeetingStateChanged(
        value: MeetingStateChanged(active: true, suggestedTitle: 'Standup'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('meeting_assist_panel')), findsOneWidget);
    expect(find.text('Standup'), findsOneWidget);

    hub.eventsController.add(
      const NativeEventMeetingTranscriptTurn(
        value: MeetingTranscriptTurn(
          speaker: 'Them',
          text: 'When do we ship the beta?',
          occurredAtMs: 1000,
        ),
      ),
    );
    hub.eventsController.add(
      const NativeEventMeetingInsight(
        value: MeetingInsight(
          kind: 'response',
          text: 'The beta ships Friday after QA signs off.',
          sourceText: 'When do we ship the beta?',
          speaker: 'Them',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('When do we ship the beta?', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Them', findRichText: true), findsWidgets);
    expect(find.text('SUGGESTED ANSWER · Them'), findsOneWidget);
    expect(
      find.text('The beta ships Friday after QA signs off.'),
      findsOneWidget,
    );
    expect(hub.searchQueries, ['When do we ship the beta?']);

    hub.eventsController.add(
      NativeEventMemorySearchResults(
        value: MemorySearchResults(
          requestId: hub.searchRequestIds.single,
          query: 'When do we ship the beta?',
          items: const [
            MemorySearchItem(
              kind: 'fact',
              id: 'claim-1',
              excerpt: 'Beta release is planned for Friday.',
              relevanceBasisPoints: 9000,
              evidenceIds: [],
            ),
          ],
          gaps: const [],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('FROM MEMORY'), findsOneWidget);
    expect(find.text('Beta release is planned for Friday.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('meeting_jot_field')),
      'pricing follow-up',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(hub.jots, ['pricing follow-up']);

    await tester.tap(find.byKey(const Key('meeting_stop')));
    await tester.pump();
    expect(hub.stops, 1);

    hub.eventsController.add(
      const NativeEventMeetingStateChanged(
        value: MeetingStateChanged(active: false, suggestedTitle: null),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('meeting_assist_panel')), findsNothing);
  });

  testWidgets('an unattributed turn renders without a speaker prefix', (
    tester,
  ) async {
    final (services, hub) = await servicesWithHub();
    addTearDown(services.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MeetingAssistPanel(services: services)),
      ),
    );
    hub.eventsController.add(
      const NativeEventMeetingStateChanged(
        value: MeetingStateChanged(active: true, suggestedTitle: 'Sync'),
      ),
    );
    hub.eventsController.add(
      const NativeEventMeetingTranscriptTurn(
        value: MeetingTranscriptTurn(
          speaker: '',
          text: 'Nobody knows who said this.',
          occurredAtMs: 5,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final turn = tester.widget<Text>(
      find.ancestor(
        of: find.textContaining(
          'Nobody knows who said this.',
          findRichText: true,
        ),
        matching: find.byType(Text),
      ),
    );
    expect(turn.textSpan?.toPlainText(), 'Nobody knows who said this.');
  });

  testWidgets('a silent far end warns that only the microphone is recorded', (
    tester,
  ) async {
    final (services, hub) = await servicesWithHub();
    addTearDown(services.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MeetingAssistPanel(services: services)),
      ),
    );
    hub.eventsController.add(
      const NativeEventMeetingStateChanged(
        value: MeetingStateChanged(active: true, suggestedTitle: 'Sync'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('meeting_far_end_warning')), findsNothing);

    hub.eventsController.add(
      const NativeEventError(
        value: NativeError(
          requestId: 'meeting-capture',
          code: 'meeting_far_end_silent',
          message: 'only your microphone is being recorded',
          retryable: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('meeting_far_end_warning')), findsOneWidget);

    hub.eventsController.add(
      const NativeEventMeetingStateChanged(
        value: MeetingStateChanged(active: true, suggestedTitle: 'Sync'),
      ),
    );
    hub.eventsController.add(
      const NativeEventMeetingStateChanged(
        value: MeetingStateChanged(active: false, suggestedTitle: null),
      ),
    );
    hub.eventsController.add(
      const NativeEventMeetingStateChanged(
        value: MeetingStateChanged(active: true, suggestedTitle: 'Sync'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('meeting_far_end_warning')), findsNothing);
  });
}

final class _RecordingMeetingHub implements NativeHub, MeetingHub {
  final eventsController = StreamController<NativeEvent>.broadcast();
  final jots = <String>[];
  final searchQueries = <String>[];
  final searchRequestIds = <String>[];
  int stops = 0;

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => eventsController.stream;

  @override
  Future<void> initialize() async {}

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #jotMeetingNote:
        jots.add(invocation.namedArguments[#text] as String);
      case #stopMeeting:
        stops += 1;
      case #search:
        searchQueries.add(invocation.namedArguments[#query] as String);
        searchRequestIds.add(invocation.namedArguments[#requestId] as String);
      default:
        break;
    }
    return null;
  }
}

final class _SignedInGateway implements AuthGateway {
  final _session = AuthSession(
    uid: 'user-panel',
    idToken: 'token-user-panel',
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
