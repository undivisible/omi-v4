import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/speech_profiles_screen.dart';
import 'package:omi/native/native_hub.dart';

SpeechProfileRecord _record(
  String id, {
  String? displayName,
  String kind = 'other',
  bool learningPaused = false,
  int embeddingCount = 3,
}) => SpeechProfileRecord(
  id: id,
  kind: kind,
  displayName: displayName,
  createdAtMs: 1000,
  updatedAtMs: 2000,
  learningPaused: learningPaused,
  embeddingCount: embeddingCount,
);

void main() {
  Future<(AppServices, _RecordingSpeechHub)> servicesWithHub() async {
    final auth = AuthController(
      _SignedInGateway(),
      consentStore: VolatileConsentStore()
        ..receipt = ProcessingConsentReceipt.current(
          subjectUid: 'user-voices',
          acceptedAt: DateTime.utc(2026, 7, 21),
        ),
    );
    await auth.restoreSession();
    final hub = _RecordingSpeechHub();
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

  Future<(AppServices, _RecordingSpeechHub)> openScreen(
    WidgetTester tester,
  ) async {
    final (services, hub) = await servicesWithHub();
    addTearDown(services.dispose);
    await tester.pumpWidget(
      MaterialApp(home: SpeechProfilesScreen(services: services)),
    );
    await tester.pump();
    await tester.pump();
    return (services, hub);
  }

  void answer(
    _RecordingSpeechHub hub,
    SpeechProfilePayload payload, {
    String? requestId,
  }) {
    hub.eventsController.add(
      NativeEventSpeechProfiles(
        value: SpeechProfileUpdate(
          requestId: requestId ?? hub.requestIds.last,
          payload: payload,
        ),
      ),
    );
  }

  testWidgets('lists named, unnamed and paused voices', (tester) async {
    final (_, hub) = await openScreen(tester);
    expect(hub.listScopes, hasLength(1));
    expect(hub.listScopes.single.uid, 'user-voices');

    answer(
      hub,
      SpeechProfilePayloadProfiles(
        profiles: [
          _record('p1', displayName: 'Ada', kind: 'owner', embeddingCount: 12),
          _record('p2'),
          _record('p3', displayName: 'Grace', learningPaused: true),
        ],
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('speech_profiles_list')), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('You · 12 voiceprints'), findsOneWidget);
    expect(find.text('Unnamed voice'), findsOneWidget);
    expect(find.text('Give this voice a name'), findsOneWidget);
    expect(find.text('Someone else · 3 voiceprints'), findsOneWidget);
    expect(find.text('Grace · 3 voiceprints · Learning paused'), findsNothing);
    expect(
      find.text('Someone else · 3 voiceprints · Learning paused'),
      findsOneWidget,
    );
  });

  testWidgets('an unavailable hub shows the detail, not an empty list', (
    tester,
  ) async {
    final (_, hub) = await openScreen(tester);
    answer(
      hub,
      const SpeechProfilePayloadUnavailable(
        detail: 'Speaker recognition is off until a model is installed.',
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('speech_profiles_unavailable')),
      findsOneWidget,
    );
    expect(
      find.text('Speaker recognition is off until a model is installed.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('speech_profiles_empty')), findsNothing);
    expect(find.byKey(const Key('speech_profiles_list')), findsNothing);
  });

  testWidgets('no profiles at all reads as nothing learned yet', (
    tester,
  ) async {
    final (_, hub) = await openScreen(tester);
    answer(hub, const SpeechProfilePayloadProfiles(profiles: []));
    await tester.pump();

    expect(find.byKey(const Key('speech_profiles_empty')), findsOneWidget);
    expect(find.text('No voices learned yet'), findsOneWidget);
    expect(find.byKey(const Key('speech_profiles_unavailable')), findsNothing);
  });

  testWidgets('naming an unnamed voice sends the rename command', (
    tester,
  ) async {
    final (_, hub) = await openScreen(tester);
    answer(hub, SpeechProfilePayloadProfiles(profiles: [_record('p2')]));
    await tester.pump();

    await tester.tap(find.byKey(const Key('speech_profile_name_p2')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('speech_profile_name_field')),
      'Alan',
    );
    await tester.tap(find.byKey(const Key('speech_profile_name_save')));
    await tester.pumpAndSettle();

    expect(hub.renames, [('p2', 'Alan')]);
  });

  testWidgets('forget only fires after the confirmation is accepted', (
    tester,
  ) async {
    final (_, hub) = await openScreen(tester);
    answer(
      hub,
      SpeechProfilePayloadProfiles(
        profiles: [_record('p1', displayName: 'Ada', embeddingCount: 12)],
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('speech_profile_menu_p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('speech_profile_forget_item_p1')));
    await tester.pumpAndSettle();
    expect(find.text('Forget Ada?'), findsOneWidget);
    expect(
      find.textContaining('Omi deletes all 12 voiceprints it holds for Ada'),
      findsOneWidget,
    );
    expect(find.textContaining('cannot be recovered'), findsOneWidget);
    expect(hub.forgets, isEmpty);

    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(hub.forgets, isEmpty);

    await tester.tap(find.byKey(const Key('speech_profile_menu_p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('speech_profile_forget_item_p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('speech_profile_forget_confirm')));
    await tester.pumpAndSettle();
    expect(hub.forgets, ['p1']);
  });

  testWidgets('merge picks a target and only fires after confirmation', (
    tester,
  ) async {
    final (_, hub) = await openScreen(tester);
    answer(
      hub,
      SpeechProfilePayloadProfiles(
        profiles: [
          _record('p1', displayName: 'Ada', embeddingCount: 7),
          _record('p3', displayName: 'Grace'),
        ],
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('speech_profile_menu_p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('speech_profile_merge_item_p1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('speech_profile_merge_target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('speech_profile_merge_target_p1')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('speech_profile_merge_target_p3')));
    await tester.pumpAndSettle();
    expect(find.text('Merge into Grace?'), findsOneWidget);
    expect(
      find.textContaining('Omi moves the 7 voiceprints held for Ada'),
      findsOneWidget,
    );
    expect(
      find.textContaining('disappears from this list for good'),
      findsOneWidget,
    );
    expect(hub.merges, isEmpty);

    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(hub.merges, isEmpty);

    await tester.tap(find.byKey(const Key('speech_profile_menu_p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('speech_profile_merge_item_p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('speech_profile_merge_target_p3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('speech_profile_merge_confirm')));
    await tester.pumpAndSettle();
    expect(hub.merges, [('p3', 'p1')]);
  });

  testWidgets('an answer for another request is ignored', (tester) async {
    final (_, hub) = await openScreen(tester);
    answer(
      hub,
      SpeechProfilePayloadProfiles(
        profiles: [_record('p1', displayName: 'Ada')],
      ),
      requestId: 'someone-elses-request',
    );
    await tester.pump();

    expect(find.text('Ada'), findsNothing);
    expect(find.byKey(const Key('speech_profiles_loading')), findsOneWidget);
  });
}

final class _RecordingSpeechHub implements NativeHub {
  final eventsController = StreamController<NativeEvent>.broadcast();
  final requestIds = <String>[];
  final listScopes = <SpeechProfileScope>[];
  final renames = <(String, String?)>[];
  final merges = <(String, String)>[];
  final forgets = <String>[];
  final pauses = <(String, bool)>[];

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => eventsController.stream;

  @override
  Future<void> initialize() async {}

  @override
  void dispose() {}

  @override
  void listSpeechProfiles({
    required String requestId,
    required SpeechProfileScope scope,
  }) {
    requestIds.add(requestId);
    listScopes.add(scope);
  }

  @override
  void renameSpeechProfile({
    required String requestId,
    required SpeechProfileScope scope,
    required String profileId,
    String? displayName,
  }) {
    requestIds.add(requestId);
    renames.add((profileId, displayName));
  }

  @override
  void mergeSpeechProfiles({
    required String requestId,
    required SpeechProfileScope scope,
    required String targetProfileId,
    required String sourceProfileId,
  }) {
    requestIds.add(requestId);
    merges.add((targetProfileId, sourceProfileId));
  }

  @override
  void forgetSpeechProfile({
    required String requestId,
    required SpeechProfileScope scope,
    required String profileId,
  }) {
    requestIds.add(requestId);
    forgets.add(profileId);
  }

  @override
  void pauseSpeechLearning({
    required String requestId,
    required SpeechProfileScope scope,
    required String profileId,
    required bool paused,
  }) {
    requestIds.add(requestId);
    pauses.add((profileId, paused));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _SignedInGateway implements AuthGateway {
  final _session = AuthSession(
    uid: 'user-voices',
    idToken: 'token-user-voices',
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
  bool get supportsChannelCode => false;

  @override
  Future<AuthSession> signInWithChannelCode(String code) =>
      throw UnimplementedError();

  @override
  AuthSession? get currentSession => _session;

  @override
  Stream<AuthSession?> get sessionChanges => _changes.stream;

  @override
  Future<AuthSession?> restoreSession() async => _session;

  @override
  Future<AuthSession?> refreshSession({bool forceRefresh = false}) async =>
      _session;

  @override
  Future<void> signOut() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
