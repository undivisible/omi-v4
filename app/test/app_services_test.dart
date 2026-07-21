import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/native/generated/signals/signals.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  test('production initialization scopes memory and forwards events', () async {
    final session = _session('user-a');
    final gateway = _FakeAuthGateway(session);
    final consent = VolatileConsentStore()..receipt = _receipt('user-a');
    final auth = AuthController(gateway, consentStore: consent);
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );

    await services.initialize();
    final received = services.nativeEvents.first;
    const event = NativeEventRuntimeStatus(
      value: RuntimeStatus(
        phase: RuntimePhase.ready,
        computerUseAvailable: false,
        localAiAvailable: false,
        memoryAvailable: true,
        agentHarnessAvailable: true,
      ),
    );
    hub.eventsController.add(event);

    expect(hub.initializeCalls, 1);
    expect(hub.databasePaths, ['/tmp/user-a.sqlite3']);
    expect(hub.personIds, ['user-a']);
    expect(await received, event);
    services.dispose();
    await hub.close();
  });

  test('no current consent keeps native services inert', () async {
    final gateway = _FakeAuthGateway(_session('user-a'));
    final auth = AuthController(gateway);
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );

    await services.initialize();

    expect(hub.initializeCalls, 0);
    expect(hub.databasePaths, isEmpty);
    services.dispose();
    await hub.close();
  });

  test('in-flight transcripts enforce immutable UID-scoped payloads', () async {
    final gateway = _FakeAuthGateway(_session('user-a'));
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();
    final errors = <Object>[];
    final errorSubscription = services.nativeEvents.listen(
      (_) {},
      onError: errors.add,
    );

    final partial = NativeEventTranscriptDelta(
      value: TranscriptDelta(
        requestId: 'audio-1',
        segmentSequence: Uint64.fromBigInt(BigInt.zero),
        occurredAtMs: 1000,
        text: 'unfinished',
        finalSegment: false,
      ),
    );
    final completed = NativeEventTranscriptDelta(
      value: TranscriptDelta(
        requestId: 'audio-1',
        segmentSequence: Uint64.fromBigInt(BigInt.one),
        occurredAtMs: 2000,
        text: ' Remember this ',
        finalSegment: true,
        language: 'en',
      ),
    );
    hub.eventsController
      ..add(partial)
      ..add(completed)
      ..add(completed);
    await _waitFor(() => hub.captures.length == 1);
    hub.eventsController.add(
      completed.copyWith(
        value: completed.value.copyWith(text: 'changed evidence'),
      ),
    );
    await _waitFor(() => errors.isNotEmpty);

    expect(hub.captures.map((capture) => capture.text), ['Remember this']);
    expect(hub.captures.map((capture) => capture.source), [
      CaptureSource.omiDevice,
    ]);
    expect(hub.captures.single.occurredAtMs, 2000);
    expect(errors.single, isA<TranscriptCaptureConflict>());

    hub.eventsController.add(
      NativeEventMemoryCaptured(
        value: MemoryCaptured(
          requestId: hub.captures.single.requestId,
          sourceId: 'source-1',
          evidenceId: 'evidence-1',
        ),
      ),
    );
    hub.eventsController.add(completed);
    await Future<void>.delayed(Duration.zero);
    expect(hub.captures, hasLength(1));
    hub.eventsController.add(
      completed.copyWith(value: completed.value.copyWith(occurredAtMs: 2001)),
    );
    await _waitFor(() => errors.length == 2);
    expect(errors.last, isA<TranscriptCaptureConflict>());

    gateway.emit(_session('user-b'));
    await _waitFor(() => hub.disposeCalls == 1);
    hub.eventsController.add(completed);
    await Future<void>.delayed(Duration.zero);
    expect(hub.captures, hasLength(1));
    services.dispose();
    await errorSubscription.cancel();
    await hub.close();
  });

  test('completed transcript ledger evicts its oldest fingerprint', () async {
    final gateway = _FakeAuthGateway(_session('user-a'));
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();

    NativeEventTranscriptDelta event(int sequence) =>
        NativeEventTranscriptDelta(
          value: TranscriptDelta(
            requestId: 'stream',
            segmentSequence: Uint64.fromBigInt(BigInt.from(sequence)),
            occurredAtMs: sequence,
            text: 'segment $sequence',
            finalSegment: true,
          ),
        );
    for (var sequence = 0; sequence <= 256; sequence += 1) {
      hub.eventsController.add(event(sequence));
      await _waitFor(() => hub.captures.length == sequence + 1);
      final capture = hub.captures.last;
      hub.eventsController.add(
        NativeEventMemoryCaptured(
          value: MemoryCaptured(
            requestId: capture.requestId,
            sourceId: 'source-$sequence',
            evidenceId: 'evidence-$sequence',
          ),
        ),
      );
    }
    await Future<void>.delayed(Duration.zero);
    hub.eventsController.add(event(0));
    await _waitFor(() => hub.captures.length == 258);

    services.dispose();
    await hub.close();
  });

  test('late revoked completion cannot acknowledge same-UID regrant', () async {
    final session = _session('user-a');
    final gateway = _FakeAuthGateway(session);
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();
    final transcript = NativeEventTranscriptDelta(
      value: TranscriptDelta(
        requestId: 'same-stream',
        segmentSequence: Uint64.fromBigInt(BigInt.one),
        occurredAtMs: 4000,
        text: 'same evidence',
        finalSegment: true,
      ),
    );

    hub.eventsController.add(transcript);
    await _waitFor(() => hub.captures.length == 1);
    final oldCapture = hub.captures.single;
    await auth.revokeProcessingConsent();
    await _waitFor(() => hub.disposeCalls == 1);

    gateway.emit(session);
    await _waitFor(() => auth.snapshot.phase == AuthPhase.signedIn);
    await auth.grantProcessingConsent();
    await _waitFor(() => hub.initializeCalls == 2);
    hub.eventsController.add(transcript);
    await _waitFor(() => hub.captures.length == 2);
    final newCapture = hub.captures.last;
    expect(newCapture.ingestionKey, oldCapture.ingestionKey);
    expect(newCapture.requestId, isNot(oldCapture.requestId));

    hub.eventsController.add(
      NativeEventMemoryCaptured(
        value: MemoryCaptured(
          requestId: oldCapture.requestId,
          sourceId: 'old-source',
          evidenceId: 'old-evidence',
        ),
      ),
    );
    hub.eventsController.add(transcript);
    await Future<void>.delayed(Duration.zero);
    expect(hub.captures, hasLength(2));
    hub.eventsController.add(
      NativeEventMemoryCaptured(
        value: MemoryCaptured(
          requestId: newCapture.requestId,
          sourceId: 'new-source',
          evidenceId: 'new-evidence',
        ),
      ),
    );
    hub.eventsController.add(transcript);
    await Future<void>.delayed(Duration.zero);
    expect(hub.captures, hasLength(2));

    services.dispose();
    await hub.close();
  });

  test(
    'account switch removes authority until the new subject consents',
    () async {
      final gateway = _FakeAuthGateway(_session('user-a'));
      final consent = VolatileConsentStore()..receipt = _receipt('user-a');
      final auth = AuthController(gateway, consentStore: consent);
      await auth.restoreSession();
      final hub = _FakeHub();
      final adapter = _DeviceAdapter();
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.mobileOwner,
          adapter: adapter,
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      );
      await services.initialize();

      gateway.emit(_session('user-b'));
      await _waitFor(() => hub.disposeCalls == 1);

      expect(adapter.disconnectCalls, greaterThanOrEqualTo(2));
      expect(hub.databasePaths, ['/tmp/user-a.sqlite3']);
      expect(hub.personIds, ['user-a']);
      expect(auth.snapshot.hasProcessingAuthority, isFalse);
      services.dispose();
      await hub.close();
      await adapter.close();
    },
  );

  test('consent revocation stops capture and shuts native down', () async {
    final gateway = _FakeAuthGateway(_session('user-a'));
    final consent = VolatileConsentStore()..receipt = _receipt('user-a');
    final auth = AuthController(gateway, consentStore: consent);
    await auth.restoreSession();
    final hub = _FakeHub();
    final adapter = _DeviceAdapter();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: adapter,
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();
    hub.eventsController.add(
      NativeEventTranscriptDelta(
        value: TranscriptDelta(
          requestId: 'audio-revoked',
          segmentSequence: Uint64.fromBigInt(BigInt.zero),
          occurredAtMs: 3000,
          text: 'must not outlive consent',
          finalSegment: true,
        ),
      ),
    );
    await _waitFor(() => hub.captures.length == 1);
    hub.failCancel = true;

    await auth.revokeProcessingConsent();
    await _waitFor(() => hub.disposeCalls == 1);

    expect(adapter.disconnectCalls, greaterThanOrEqualTo(2));
    expect(hub.cancelled, contains(hub.captures.single.requestId));
    await expectLater(
      services.connectDevice('omi-1'),
      throwsA(isA<StateError>()),
    );
    services.dispose();
    await hub.close();
    await adapter.close();
  });

  test(
    'slow Firebase signout cannot delay native authority shutdown',
    () async {
      final gateway = _FakeAuthGateway(_session('user-a'))
        ..signOutBarrier = Completer<void>();
      final auth = AuthController(
        gateway,
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final adapter = _DeviceAdapter();
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.mobileOwner,
          adapter: adapter,
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      );
      await services.initialize();

      final revocation = auth.revokeProcessingConsent();
      expect(auth.snapshot.hasProcessingAuthority, isFalse);
      await _waitFor(() => hub.disposeCalls == 1);
      expect(gateway.didSignOut, isFalse);

      gateway.signOutBarrier!.complete();
      await revocation;
      expect(gateway.didSignOut, isTrue);
      services.dispose();
      await hub.close();
      await adapter.close();
    },
  );

  test('connect cannot outlive processing-consent revocation', () async {
    final gateway = _FakeAuthGateway(_session('user-a'));
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final adapter = _DeviceAdapter()..connectBarrier = Completer<void>();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: adapter,
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();

    final connection = services.connectDevice('omi-1');
    await _waitFor(() => adapter.connectCalls == 1);
    final revocation = auth.revokeProcessingConsent();
    adapter.connectBarrier!.complete();

    await expectLater(connection, throwsA(isA<StateError>()));
    await revocation;
    expect(adapter.disconnectCalls, greaterThanOrEqualTo(1));
    expect(services.deviceAudio.active, isFalse);
    services.dispose();
    await hub.close();
    await adapter.close();
  });
}

AuthSession _session(String uid) =>
    AuthSession(uid: uid, idToken: 'token-$uid', expiresAt: DateTime.utc(2030));

ProcessingConsentReceipt _receipt(String uid) =>
    ProcessingConsentReceipt.current(
      subjectUid: uid,
      acceptedAt: DateTime.utc(2026, 7, 21),
    );

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

final class _FakeAuthGateway implements AuthGateway {
  _FakeAuthGateway(this._session);

  AuthSession? _session;
  final _changes = StreamController<AuthSession?>.broadcast();
  Completer<void>? signOutBarrier;
  bool didSignOut = false;

  void emit(AuthSession? session) {
    _session = session;
    _changes.add(session);
  }

  @override
  bool get isConfigured => true;

  @override
  AuthFailure? get configurationFailure => null;

  @override
  bool get supportsPhoneOtp => true;

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
  Future<void> signOut() async {
    await signOutBarrier?.future;
    didSignOut = true;
    emit(null);
  }

  @override
  Future<AuthSession> signIn(AuthProvider provider) async => _session!;

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) async => _session!;

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) async =>
      const PhoneOtpChallenge(verificationId: 'challenge');

  @override
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) async => _session!;
}

final class _FakeHub implements NativeHub {
  final eventsController = StreamController<NativeEvent>.broadcast();
  int initializeCalls = 0;
  int disposeCalls = 0;
  final databasePaths = <String>[];
  final personIds = <String>[];
  final captures = <_Capture>[];
  final cancelled = <String>[];
  bool failCancel = false;

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => eventsController.stream;

  @override
  Future<void> initialize() async => initializeCalls += 1;

  @override
  void configureMemory({
    required String requestId,
    required String databasePath,
    required String tenantId,
    required String personId,
  }) {
    databasePaths.add(databasePath);
    personIds.add(personId);
  }

  @override
  void dispose() => disposeCalls += 1;

  Future<void> close() => eventsController.close();

  @override
  void cancel(String requestId) {
    cancelled.add(requestId);
    if (failCancel) throw StateError('cancel failed');
  }

  @override
  void capture({
    required String requestId,
    required String ingestionKey,
    required CaptureSource source,
    required int occurredAtMs,
    String? text,
    String? application,
    String? windowTitle,
  }) {
    captures.add(
      _Capture(
        requestId: requestId,
        ingestionKey: ingestionKey,
        source: source,
        occurredAtMs: occurredAtMs,
        text: text,
      ),
    );
  }

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
  }) {}

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
}

final class _Capture {
  const _Capture({
    required this.requestId,
    required this.ingestionKey,
    required this.source,
    required this.occurredAtMs,
    required this.text,
  });

  final String requestId;
  final String ingestionKey;
  final CaptureSource source;
  final int occurredAtMs;
  final String? text;
}

final class _DeviceAdapter implements DeviceRelayAdapter {
  final audio = StreamController<List<int>>.broadcast();
  final connections = StreamController<bool>.broadcast();
  int disconnectCalls = 0;
  int connectCalls = 0;
  Completer<void>? connectBarrier;

  Future<void> close() async {
    await audio.close();
    await connections.close();
  }

  @override
  DeviceRelayCapabilities get capabilities => const DeviceRelayCapabilities(
    pairing: DeviceCapabilityState.available,
    metadata: DeviceCapabilityState.available,
    audioStreaming: DeviceCapabilityState.available,
  );

  @override
  Stream<DeviceRelaySnapshot> get snapshots => const Stream.empty();

  @override
  Future<List<RelayDevice>> scan() async => const [];

  @override
  Future<RelayDevice> connect(String deviceId) async {
    connectCalls += 1;
    await connectBarrier?.future;
    return RelayDevice(
      id: deviceId,
      name: 'Omi',
      audioCodec: DeviceAudioCodec.opus,
    );
  }

  @override
  Future<void> disconnect() async => disconnectCalls += 1;

  @override
  Stream<List<int>> audioPackets(String deviceId) => audio.stream;

  @override
  Stream<bool> connectionState(String deviceId) => connections.stream;
}
