import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/mobile_companion_shell.dart';
import 'package:omi/features/mobile_onboarding_screen.dart';
import 'package:omi/features/onboarding/lightspeed.dart';
import 'package:omi/main.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/onboarding/onboarding_completion.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('auth-unavailable path advances through skip to finish', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final services = _unavailableAuthServices();
    var finished = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: MobileOnboardingScreen(
          services: services,
          pairedDevices: VolatilePairedDeviceStore(),
          onFinish: () => finished += 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mobile_onboarding_intro_continue')));
    await tester.pumpAndSettle();

    final accountContinue = tester.widget<FilledButton>(
      find.byKey(const Key('mobile_onboarding_account_continue')),
    );
    expect(accountContinue.onPressed, isNotNull);
    await tester.tap(
      find.byKey(const Key('mobile_onboarding_account_continue')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mobile_pair_scan')), findsOneWidget);
    await tester.tap(find.byKey(const Key('mobile_pair_skip')));
    await tester.pumpAndSettle();

    for (var page = 0; page < 3; page += 1) {
      await tester.tap(find.byKey(Key('mobile_teach_continue_$page')));
      await tester.pumpAndSettle();
    }

    expect(find.byKey(const Key('mobile_onboarding_finish')), findsOneWidget);
    await tester.tap(find.byKey(const Key('mobile_onboarding_finish')));
    await tester.pump();

    expect(
      find.byKey(const Key('mobile_onboarding_transition')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('lightspeed_fade')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(finished, 1);
    services.dispose();
  });

  testWidgets(
    '"Already have an account?" is tappable and skips straight to the '
    'tutorial, not the fresh pairing step',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final services = _unavailableAuthServices();

      await tester.pumpWidget(
        MaterialApp(
          home: MobileOnboardingScreen(
            services: services,
            pairedDevices: VolatilePairedDeviceStore(),
            onFinish: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = find.byKey(const Key('mobile_already_have_account'));
      expect(button, findsOneWidget);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mobile_pair_scan')), findsNothing);
      expect(find.byKey(Key('mobile_teach_continue_0')), findsOneWidget);
      services.dispose();
    },
  );

  testWidgets(
    'pair stage detects, auto-connects, persists, and auto-advances',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = _Adapter();
      final services = await _authorizedMobileServices('user-a', adapter);
      await services.initialize();
      final pairedDevices = VolatilePairedDeviceStore();

      await tester.pumpWidget(
        MaterialApp(
          home: MobileOnboardingScreen(
            services: services,
            pairedDevices: pairedDevices,
            onFinish: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('mobile_onboarding_intro_continue')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('mobile_onboarding_account_continue')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('mobile_pair_scan')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Omi detected!'), findsOneWidget);
      expect(await pairedDevices.read(), 'omi-1');
      expect(adapter.haptics, [2]);
      expect(find.byKey(const Key('mobile_pair_continue')), findsOneWidget);
      expect(find.byKey(const Key('mobile_pair_skip')), findsNothing);
      expect(find.byKey(const Key('mobile_pair_not_this_one')), findsOneWidget);
      final scale = tester.widget<AnimatedScale>(
        find.byWidgetPredicate(
          (widget) => widget is AnimatedScale && widget.child is PendantVisual,
        ),
      );
      expect(scale.scale, 1.3);

      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mobile_teach_continue_0')), findsOneWidget);
      services.dispose();
    },
  );

  testWidgets('not-this-one excludes the candidate and picks the next Omi', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adapter = _Adapter(devices: const [_omi1, _omi2]);
    final services = await _authorizedMobileServices('user-a', adapter);
    await services.initialize();
    final pairedDevices = VolatilePairedDeviceStore();

    await tester.pumpWidget(
      MaterialApp(
        home: MobileOnboardingScreen(
          services: services,
          pairedDevices: pairedDevices,
          onFinish: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobile_onboarding_intro_continue')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('mobile_onboarding_account_continue')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mobile_pair_scan')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(await pairedDevices.read(), 'omi-1');
    expect(find.text('Omi detected!'), findsOneWidget);

    await tester.tap(find.byKey(const Key('mobile_pair_not_this_one')));
    for (var round = 0; round < 4; round += 1) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));

    expect(adapter.disconnects, greaterThanOrEqualTo(1));
    expect(await pairedDevices.read(), 'omi-2');
    expect(find.text('Omi detected!'), findsOneWidget);
    expect(adapter.haptics, [2, 2]);

    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mobile_teach_continue_0')), findsOneWidget);
    services.dispose();
  });

  testWidgets('lightspeed transition plays when pendant and authority exist', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final services = await _authorizedMobileServices('user-a');
    await services.initialize();
    var finished = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: MobileOnboardingScreen(
          services: services,
          pairedDevices: VolatilePairedDeviceStore(),
          onFinish: () => finished += 1,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobile_onboarding_intro_continue')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('mobile_onboarding_account_continue')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mobile_pair_scan')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('mobile_pair_continue')));
    await tester.pumpAndSettle();

    for (var page = 0; page < 3; page += 1) {
      await tester.tap(find.byKey(Key('mobile_teach_continue_$page')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const Key('mobile_onboarding_finish')));
    await tester.pump();

    expect(find.byKey(const Key('lightspeed_paint')), findsOneWidget);
    expect(finished, 0);
    await tester.pump(const Duration(milliseconds: 800));
    expect(finished, 0);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(finished, 1);
    services.dispose();
  });

  testWidgets('lightspeed transition skips ahead with animations disabled', (
    tester,
  ) async {
    var completed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: LightspeedTransition(
            mode: LightspeedMode.lightspeed,
            onCompleted: () => completed += 1,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(completed, 1);
  });

  testWidgets('mobile platforms with incomplete onboarding see mobile flow', (
    tester,
  ) async {
    final services = await _authorizedServices('user-a');

    await tester.pumpWidget(
      OmiApp(
        services: services,
        onboardingCompletionStore: VolatileOnboardingCompletionStore(),
        platformOverride: TargetPlatform.iOS,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MobileOnboardingScreen), findsOneWidget);
    expect(
      find.byKey(const Key('mobile_onboarding_intro_continue')),
      findsOneWidget,
    );
  });

  testWidgets('intro hero renders and advances to the account stage', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final services = _unavailableAuthServices();

    await tester.pumpWidget(
      MaterialApp(
        home: MobileOnboardingScreen(
          services: services,
          pairedDevices: VolatilePairedDeviceStore(),
          onFinish: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('second brain'), findsOneWidget);
    expect(find.text('Hi Omi!'), findsOneWidget);
    expect(
      find.byKey(const Key('mobile_already_have_account')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('mobile_onboarding_account_continue')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('mobile_onboarding_intro_continue')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('mobile_onboarding_account_continue')),
      findsOneWidget,
    );
    services.dispose();
  });

  testWidgets('primary button keeps a fixed position across stages', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final services = _unavailableAuthServices();

    await tester.pumpWidget(
      MaterialApp(
        home: MobileOnboardingScreen(
          services: services,
          pairedDevices: VolatilePairedDeviceStore(),
          onFinish: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mobile_onboarding_intro_continue')));
    await tester.pumpAndSettle();

    Rect slot() =>
        tester.getRect(find.byKey(const Key('mobile_onboarding_primary_slot')));
    final accountSlot = slot();

    await tester.tap(
      find.byKey(const Key('mobile_onboarding_account_continue')),
    );
    await tester.pumpAndSettle();
    expect(slot(), accountSlot);

    await tester.tap(find.byKey(const Key('mobile_pair_skip')));
    await tester.pumpAndSettle();
    expect(slot(), accountSlot);

    for (var page = 0; page < 3; page += 1) {
      await tester.tap(find.byKey(Key('mobile_teach_continue_$page')));
      await tester.pumpAndSettle();
      expect(slot(), accountSlot);
    }
    services.dispose();
  });

  testWidgets('successful pairing sends a haptic to the pendant', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adapter = _Adapter();
    final services = await _authorizedMobileServices('user-a', adapter);
    await services.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: MobileOnboardingScreen(
          services: services,
          pairedDevices: VolatilePairedDeviceStore(),
          onFinish: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobile_onboarding_intro_continue')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('mobile_onboarding_account_continue')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobile_pair_scan')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(adapter.haptics, [2]);
    services.dispose();
  });

  testWidgets('desktop install notice shows, dismisses, and stays dismissed', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final services = _unavailableAuthServices();

    Widget shell() => MaterialApp(
      home: MobileCompanionShell(
        services: services,
        pairedDevices: VolatilePairedDeviceStore(),
      ),
    );

    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('companion_desktop_notice_tile')),
      findsOneWidget,
    );
    expect(
      find.text('Omi learns more about you from your Mac or Windows PC.'),
      findsOneWidget,
    );

    await tester.ensureVisible(
      find.byKey(const Key('companion_desktop_notice_dismiss')),
    );
    await tester.tap(find.byKey(const Key('companion_desktop_notice_dismiss')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('companion_desktop_notice_tile')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('companion_desktop_notice_tile')),
      findsNothing,
    );
    services.dispose();
  });
}

AuthSession _session(String uid) =>
    AuthSession(uid: uid, idToken: 'token-$uid', expiresAt: DateTime.utc(2030));

AppServices _unavailableAuthServices() => AppServices.forTesting(
  nativeHub: const UnavailableNativeHub('test'),
  deviceRelay: DeviceRelayService(
    role: DeviceRelayRole.mobileOwner,
    adapter: _Adapter(),
  ),
  auth: AuthController(const UnconfiguredAuthGateway()),
  memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
);

Future<AuthController> _authorizedAuth(String uid) async {
  final auth = AuthController(
    _Gateway(_session(uid)),
    consentStore: VolatileConsentStore(),
  );
  await auth.setConsent(true);
  await auth.grantProcessingConsent();
  return auth;
}

Future<AppServices> _authorizedServices(String uid) async =>
    AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: await _authorizedAuth(uid),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );

Future<AppServices> _authorizedMobileServices(
  String uid, [
  _Adapter? adapter,
]) async => AppServices.forTesting(
  nativeHub: _Hub(),
  deviceRelay: DeviceRelayService(
    role: DeviceRelayRole.mobileOwner,
    adapter: adapter ?? _Adapter(),
  ),
  auth: await _authorizedAuth(uid),
  memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
  managedStt: _ManagedStt(
    ManagedSttSession(
      websocketUrl: 'wss://api.example.test/v1/stt/sessions/s/stream',
      session: _session(uid),
    ),
  ),
);

final class _ManagedStt implements ManagedSttClient {
  _ManagedStt(this.result);

  final ManagedSttSession result;

  @override
  Uri get trustedWorkerOrigin => Uri.parse('https://api.example.test/');

  @override
  Future<ManagedSttSession> createSession({
    required String idempotencyKey,
    required String deviceId,
    required String language,
    required ManagedSttEncoding encoding,
    required int sampleRate,
    required int channels,
  }) async => result;
}

final class _Gateway implements AuthGateway {
  _Gateway(this.currentSession);

  @override
  AuthSession? currentSession;

  @override
  AuthFailure? get configurationFailure => null;

  @override
  bool get isConfigured => true;

  @override
  Stream<AuthSession?> get sessionChanges => const Stream.empty();

  @override
  bool get supportsDesktopBrowserHandoff => false;

  @override
  bool get supportsPhoneOtp => true;

  @override
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) async => currentSession!;

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) async =>
      const PhoneOtpChallenge(verificationId: 'test');

  @override
  Future<AuthSession?> refreshSession() async => currentSession;

  @override
  Future<AuthSession?> restoreSession() async => currentSession;

  @override
  Future<AuthSession> signIn(AuthProvider provider) async => currentSession!;

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) async => currentSession!;

  @override
  Future<void> signOut() async => currentSession = null;
}

const _omi1 = RelayDevice(
  id: 'omi-1',
  name: 'Omi Pendant',
  signalStrength: -52,
  batteryLevel: 87,
  firmwareRevision: '1.0.3',
  audioCodec: DeviceAudioCodec.opus,
);

const _omi2 = RelayDevice(
  id: 'omi-2',
  name: 'Omi Pendant',
  signalStrength: -61,
  batteryLevel: 64,
  firmwareRevision: '1.0.3',
  audioCodec: DeviceAudioCodec.opus,
);

final class _Adapter implements DeviceRelayAdapter, DeviceRelayHaptics {
  _Adapter({this.devices = const [_omi1]});

  final List<RelayDevice> devices;
  final haptics = <int>[];
  var disconnects = 0;
  final _snapshots = StreamController<DeviceRelaySnapshot>.broadcast();
  final _audio = StreamController<List<int>>.broadcast();
  final _connections = StreamController<bool>.broadcast();

  @override
  Future<bool> sendHaptic(int level) async {
    haptics.add(level);
    return true;
  }

  @override
  DeviceRelayCapabilities get capabilities => const DeviceRelayCapabilities(
    pairing: DeviceCapabilityState.available,
    metadata: DeviceCapabilityState.available,
    audioStreaming: DeviceCapabilityState.available,
  );

  @override
  Stream<DeviceRelaySnapshot> get snapshots => _snapshots.stream;

  @override
  Future<List<RelayDevice>> scan() async => devices;

  @override
  Future<RelayDevice> connect(String deviceId) async {
    final device = devices.firstWhere((next) => next.id == deviceId);
    _snapshots.add(
      DeviceRelaySnapshot(
        phase: DeviceConnectionPhase.connected,
        capabilities: capabilities,
        device: device,
      ),
    );
    return device;
  }

  @override
  Future<void> disconnect() async {
    disconnects += 1;
    _snapshots.add(
      DeviceRelaySnapshot(
        phase: DeviceConnectionPhase.disconnected,
        capabilities: capabilities,
      ),
    );
  }

  @override
  Stream<List<int>> audioPackets(String deviceId) => _audio.stream;

  @override
  Stream<bool> connectionState(String deviceId) => _connections.stream;
}

final class _Hub implements NativeHub {
  final events0 = StreamController<NativeEvent>.broadcast();

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => events0.stream;

  @override
  Future<void> initialize() async {}

  @override
  void configureMemory({
    required String requestId,
    required String databasePath,
    required String tenantId,
    required String personId,
  }) {}

  @override
  void capture({
    required String requestId,
    required String ingestionKey,
    required CaptureSource source,
    required int occurredAtMs,
    required int recordedAtMs,
    String? text,
    String? application,
    String? windowTitle,
    TranscriptLocator? transcriptLocator,
  }) {}

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  }) {}

  @override
  void exportMemory({
    required String requestId,
    int afterCommit = 0,
    int afterEventIndex = -1,
    int? highWaterMark,
    int limit = 100,
  }) {}

  @override
  void listMemoryItems({required String requestId, int limit = 50}) {}

  @override
  void correctMemory({
    required String requestId,
    required String claimId,
    required String text,
    required String value,
    required int occurredAtMs,
    required int recordedAtMs,
  }) {}

  @override
  void deleteMemorySource({
    required String requestId,
    required String sourceId,
    required int deletedAtMs,
  }) {}

  @override
  void sendMessage({
    required String requestId,
    required String text,
    String? conversationId,
    String? memoryContext,
  }) {}

  @override
  void configureAssistant({
    required String requestId,
    required AssistantProvider provider,
    required String model,
    required String credential,
    String? endpoint,
  }) {}

  @override
  void configureTrustedAssistant({
    required String requestId,
    required String managedWorkerOrigin,
  }) {}

  @override
  void clearAssistant(String requestId) {}

  @override
  void decideApproval({
    required String requestId,
    required String proposalId,
    required ApprovalDecision decision,
    ComputerUseAuthorityReceipt? authorityReceipt,
  }) {}

  @override
  void startTranscription({
    required String requestId,
    required String audioStreamId,
    required String deviceId,
    required TranscriptionAuth auth,
    required String language,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
  }) {
    events0.add(
      NativeEventTranscriptionStatus(
        value: TranscriptionStatus(
          requestId: requestId,
          audioStreamId: audioStreamId,
          state: TranscriptionState.started,
          sttEpoch: 0,
        ),
      ),
    );
  }

  @override
  void stopTranscription({
    required String requestId,
    required String audioStreamId,
  }) {
    events0.add(
      NativeEventTranscriptionStopAcknowledged(
        value: TranscriptionStopAcknowledgement(
          requestId: requestId,
          audioStreamId: audioStreamId,
          accepted: true,
        ),
      ),
    );
  }

  @override
  void cancel(String requestId) {}

  @override
  void sendAudio({
    required String requestId,
    required int sequence,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
    required bool endOfStream,
    required Uint8List bytes,
  }) {}

  @override
  void dispose() {}
}
