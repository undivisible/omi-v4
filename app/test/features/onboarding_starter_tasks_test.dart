import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/capabilities/desktop_capabilities.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/onboarding_screen.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/onboarding/hub_checklist.dart';

final class _AllGrantedCapabilities implements DesktopCapabilityGateway {
  @override
  Future<Map<CoreCapability, CapabilityStatus>> check() async => {
    for (final capability in CoreCapability.values)
      capability: const CapabilityStatus(
        state: CapabilityState.granted,
        detail: 'Verified',
      ),
  };

  @override
  Future<void> request(CoreCapability capability) async {}

  @override
  Future<void> dismissOverlay() async {}
}

final class _ScanHub implements NativeHub, OnboardingScanHub {
  final eventsController = StreamController<NativeEvent>.broadcast();
  final scanRequests = <String>[];

  @override
  bool available = true;

  Future<void> close() => eventsController.close();

  @override
  Stream<NativeEvent> get events => eventsController.stream;

  @override
  Future<void> initialize() async {}

  @override
  void scanOnboarding({
    required String requestId,
    required List<String> roots,
    required bool includeAppleNotes,
    required bool includeAppleMail,
    required int recordedAtMs,
  }) {
    scanRequests.add(requestId);
  }

  @override
  void dispose() {}

  @override
  Object? noSuchMethod(Invocation invocation) => null;
}

final class _HangingCurrentsTransport implements CurrentsTransport {
  const _HangingCurrentsTransport();

  @override
  Future<CurrentsResponse> send(CurrentsRequest request) =>
      Completer<CurrentsResponse>().future;
}

void main() {
  Future<void> reachProfileStep(
    WidgetTester tester,
    _ScanHub hub,
    AppServices services,
    HubChecklistStore store, {
    Duration starterTaskTimeout = const Duration(seconds: 8),
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingScreen(
          services: services,
          capabilities: _AllGrantedCapabilities(),
          checklistStore: store,
          starterTaskTimeout: starterTaskTimeout,
          onFinish: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('continue_preview_intro')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(hub.scanRequests, hasLength(1));
    hub.eventsController.add(
      NativeEventOnboardingScanCompleted(
        value: OnboardingScanCompleted(
          requestId: hub.scanRequests.single,
          sources: [
            OnboardingScanSource(
              source: 'workspace',
              state: OnboardingScanState.complete,
              detail: 'projects',
              itemsFound: Uint64.fromBigInt(BigInt.from(7)),
            ),
          ],
          summary:
              'You keep **Alpenglow** moving and a decision waits in the '
              '**desktop handoff** thread.',
          detectedName: 'Max',
          detectedLanguages: const ['English'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('keep_profile')), findsOneWidget);
  }

  testWidgets(
    'local mode derives starter tasks from the scan before onboarding '
    'advances past the profile step',
    (tester) async {
      final hub = _ScanHub();
      final services = AppServices.forTesting(
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        auth: AuthController(const UnconfiguredAuthGateway()),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      );
      addTearDown(services.dispose);
      addTearDown(hub.close);
      final store = VolatileHubChecklistStore();

      await reachProfileStep(tester, hub, services, store);
      await tester.ensureVisible(find.byKey(const Key('keep_profile')));
      await tester.tap(find.byKey(const Key('keep_profile')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // Tasks were seeded from the user's own scan data before the use step.
      expect(find.byKey(const Key('shift_left')), findsOneWidget);
      expect(store.tasks, isNotEmpty);
      expect(store.tasks.length, inInclusiveRange(2, 4));
      expect(store.tasks[0], contains('Alpenglow'));
      expect(store.tasks[1], contains('desktop handoff'));
      expect(store.tasks.join(), contains('workspace'));
    },
  );

  testWidgets(
    'a signed-in currents generate cycle that never responds shows the '
    'preparing state, times out, and continues with derived tasks',
    (tester) async {
      final hub = _ScanHub();
      final gateway = _FakeSignedInGateway();
      final auth = AuthController(gateway);
      await auth.setConsent(true);
      await auth.signIn(AuthProvider.google);
      await auth.grantProcessingConsent();
      expect(auth.snapshot.hasProcessingAuthority, isTrue);
      final worker = WorkerHttpClient(
        baseUri: Uri.parse('https://worker.invalid'),
        sessionProvider: auth.validSession,
      );
      final services = AppServices.forTesting(
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        auth: auth,
        currentsClient: const CurrentsClient(_HangingCurrentsTransport()),
        worker: worker,
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      );
      addTearDown(services.dispose);
      addTearDown(hub.close);
      final store = VolatileHubChecklistStore();

      await reachProfileStep(
        tester,
        hub,
        services,
        store,
        starterTaskTimeout: const Duration(milliseconds: 400),
      );
      await tester.ensureVisible(find.byKey(const Key('keep_profile')));
      await tester.tap(find.byKey(const Key('keep_profile')));
      await tester.pump(const Duration(milliseconds: 100));

      // The bounded wait is visible while the generate cycle hangs.
      expect(find.byKey(const Key('preparing_tasks')), findsOneWidget);
      expect(find.text('Preparing your tasks…'), findsOneWidget);

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // Timed out gracefully: onboarding advanced and local derivation
      // still produced the starter tasks.
      expect(find.byKey(const Key('shift_left')), findsOneWidget);
      expect(store.tasks, isNotEmpty);
      expect(store.tasks[0], contains('Alpenglow'));
    },
  );
}

final class _FakeSignedInGateway implements AuthGateway {
  final session = AuthSession(
    uid: 'uid-1',
    idToken: 'token-1',
    expiresAt: DateTime.utc(2031),
  );

  @override
  bool get isConfigured => true;

  @override
  AuthFailure? get configurationFailure => null;

  @override
  bool get supportsPhoneOtp => false;

  @override
  bool get supportsDesktopBrowserHandoff => false;

  @override
  AuthSession? currentSession;

  @override
  Stream<AuthSession?> get sessionChanges => const Stream.empty();

  @override
  Future<AuthSession?> restoreSession() async => null;

  @override
  Future<AuthSession?> refreshSession() async => currentSession;

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) => throw UnimplementedError();

  @override
  Future<AuthSession> signIn(AuthProvider provider) async {
    currentSession = session;
    return session;
  }

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) => throw UnimplementedError();

  @override
  Future<void> signOut() async {
    currentSession = null;
  }
}
