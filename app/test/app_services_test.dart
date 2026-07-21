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

    await auth.revokeProcessingConsent();
    await _waitFor(() => hub.disposeCalls == 1);

    expect(adapter.disconnectCalls, greaterThanOrEqualTo(2));
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
  void cancel(String requestId) {}

  @override
  void capture({
    required String requestId,
    required CaptureSource source,
    required int occurredAtMs,
    String? text,
    String? application,
    String? windowTitle,
  }) {}

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
