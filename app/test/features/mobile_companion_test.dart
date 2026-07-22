import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/mobile_companion_shell.dart';
import 'package:omi/main.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/onboarding/onboarding_completion.dart';

void main() {
  test('probe connectDevice completes', () async {
    final fixture = await _mobileFixture('user-a');
    final device = await fixture.services
        .connectDevice('omi-1')
        .timeout(const Duration(seconds: 5));
    expect(device.id, 'omi-1');
    fixture.services.dispose();
  });

  testWidgets('mobile platforms route to the companion shell', (tester) async {
    final services = await _authorizedServices('user-a');
    final store = VolatileOnboardingCompletionStore();
    await store.complete('user-a');

    await tester.pumpWidget(
      OmiApp(
        services: services,
        onboardingCompletionStore: store,
        platformOverride: TargetPlatform.iOS,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion_tab_device')), findsOneWidget);
    expect(find.byKey(const Key('chat_input')), findsNothing);
  });

  testWidgets('desktop platforms keep the existing hub shell', (tester) async {
    final services = await _authorizedServices('user-a');
    final store = VolatileOnboardingCompletionStore();
    await store.complete('user-a');

    await tester.pumpWidget(
      OmiApp(
        services: services,
        onboardingCompletionStore: store,
        platformOverride: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat_input')), findsOneWidget);
    expect(find.byKey(const Key('companion_tab_device')), findsNothing);
  });

  testWidgets('pairing flow scans, connects, remembers, and shows status', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');
    final pairedDevices = VolatilePairedDeviceStore();

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: pairedDevices,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('companion_scan')));
    await tester.pumpAndSettle();
    expect(find.text('Omi Pendant'), findsOneWidget);

    await tester.tap(find.byKey(const Key('companion_connect_omi-1')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(await pairedDevices.read(), 'omi-1');
    expect(find.byKey(const Key('companion_battery_tile')), findsOneWidget);
    expect(find.text('87%'), findsOneWidget);
    expect(find.text('Opus 16 kHz'), findsOneWidget);
    expect(find.text('1.0.3'), findsOneWidget);
    expect(fixture.services.deviceAudio.active, isTrue);
    final captureSwitch = tester.widget<Switch>(
      find.byKey(const Key('companion_capture_switch')),
    );
    expect(captureSwitch.value, isTrue);

    await tester.tap(find.byKey(const Key('companion_disconnect')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(fixture.services.deviceAudio.active, isFalse);
    expect(find.byKey(const Key('companion_scan_tile')), findsOneWidget);
    expect(
      find.byKey(const Key('companion_remembered_tile')),
      findsOneWidget,
    );
    fixture.services.dispose();
  });

  testWidgets('capture tab lists only final transcript segments', (
    tester,
  ) async {
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('companion_tab_capture')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('companion_transcripts_empty')),
      findsOneWidget,
    );

    fixture.hub.events0
      ..add(
        NativeEventTranscriptDelta(
          value: _delta('still speaking', finalSegment: false),
        ),
      )
      ..add(
        NativeEventTranscriptDelta(
          value: _delta('hello from the pendant', finalSegment: true),
        ),
      );
    await tester.pumpAndSettle();

    expect(find.text('hello from the pendant'), findsOneWidget);
    expect(find.text('still speaking'), findsNothing);
    expect(find.byKey(const Key('companion_transcripts_empty')), findsNothing);
    fixture.services.dispose();
  });

  testWidgets('settings tab shows account, consent, route, and version', (
    tester,
  ) async {
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('companion_tab_settings')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion_account_tile')), findsOneWidget);
    expect(find.byKey(const Key('companion_consent_tile')), findsOneWidget);
    expect(find.byKey(const Key('companion_route_tile')), findsOneWidget);
    expect(find.byKey(const Key('companion_version_tile')), findsOneWidget);
    expect(find.text('Managed Omi transcription.'), findsOneWidget);
    expect(find.byKey(const Key('companion_sign_out')), findsOneWidget);
    fixture.services.dispose();
  });
}

TranscriptDelta _delta(String text, {required bool finalSegment}) =>
    TranscriptDelta(
      requestId: 'start-req',
      audioStreamId: 'stream-1',
      segmentId: 'segment-$text',
      segmentSequence: Uint64.fromBigInt(BigInt.zero),
      sttEpoch: 0,
      deviceId: 'omi-1',
      provider: 'managed',
      startMs: 0,
      endMs: 1,
      occurredAtMs: DateTime.utc(2026, 7, 22).millisecondsSinceEpoch,
      text: text,
      finalSegment: finalSegment,
    );

AuthSession _session(String uid) =>
    AuthSession(uid: uid, idToken: 'token-$uid', expiresAt: DateTime.utc(2030));

Future<AuthController> _authorizedAuth(String uid) async {
  final auth = AuthController(
    _Gateway(_session(uid)),
    consentStore: VolatileConsentStore(),
  );
  await auth.setConsent(true);
  await auth.grantProcessingConsent();
  return auth;
}

Future<AppServices> _authorizedServices(String uid) async {
  final auth = await _authorizedAuth(uid);
  return AppServices.forTesting(
    nativeHub: const UnavailableNativeHub('test'),
    deviceRelay: DeviceRelayService(
      role: DeviceRelayRole.desktopObserver,
      adapter: const UnavailableDeviceRelayAdapter(),
    ),
    auth: auth,
    memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
  );
}

Future<({AppServices services, _Hub hub, _Adapter adapter})> _mobileFixture(
  String uid,
) async {
  final auth = await _authorizedAuth(uid);
  final hub = _Hub();
  final adapter = _Adapter();
  final services = AppServices.forTesting(
    nativeHub: hub,
    deviceRelay: DeviceRelayService(
      role: DeviceRelayRole.mobileOwner,
      adapter: adapter,
    ),
    auth: auth,
    memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    managedStt: _ManagedStt(
      ManagedSttSession(
        websocketUrl: 'wss://api.example.test/v1/stt/sessions/s/stream',
        session: _session(uid),
      ),
    ),
  );
  await services.initialize();
  return (services: services, hub: hub, adapter: adapter);
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

final class _Adapter implements DeviceRelayAdapter {
  int connectCalls = 0;
  final _snapshots = StreamController<DeviceRelaySnapshot>.broadcast();
  final _audio = StreamController<List<int>>.broadcast();
  final _connections = StreamController<bool>.broadcast();

  static const _device = RelayDevice(
    id: 'omi-1',
    name: 'Omi Pendant',
    signalStrength: -52,
    batteryLevel: 87,
    firmwareRevision: '1.0.3',
    audioCodec: DeviceAudioCodec.opus,
  );

  @override
  DeviceRelayCapabilities get capabilities => const DeviceRelayCapabilities(
    pairing: DeviceCapabilityState.available,
    metadata: DeviceCapabilityState.available,
    audioStreaming: DeviceCapabilityState.available,
  );

  @override
  Stream<DeviceRelaySnapshot> get snapshots => _snapshots.stream;

  @override
  Future<List<RelayDevice>> scan() async => const [_device];

  @override
  Future<RelayDevice> connect(String deviceId) async {
    connectCalls += 1;
    _snapshots.add(
      DeviceRelaySnapshot(
        phase: DeviceConnectionPhase.connected,
        capabilities: capabilities,
        device: _device,
      ),
    );
    return _device;
  }

  @override
  Future<void> disconnect() async {
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
