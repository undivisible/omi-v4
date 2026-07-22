import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/capabilities/desktop_capabilities.dart';
import 'package:omi/features/desktop_auth_screen.dart';
import 'package:omi/features/onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final session = AuthSession(
    uid: 'firebase-uid',
    idToken: 'firebase-token',
    expiresAt: DateTime.utc(2030),
    phoneNumber: '+15555550123',
  );

  testWidgets(
    'processing consent and Firebase phone disclosure stay separate',
    (tester) async {
      final gateway = _Gateway(session);
      final store = VolatileConsentStore();
      final auth = AuthController(gateway, consentStore: store);

      await tester.pumpWidget(_controls(auth));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('request_phone_otp')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const Key('firebase_auth_acknowledgement')));
      await tester.pumpAndSettle();
      expect(auth.snapshot.consentGranted, isTrue);
      expect(await store.currentReceipt(), isNull);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('request_phone_otp')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const Key('firebase_phone_disclosure')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('request_phone_otp')))
            .onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(const Key('sign_in_google')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('grant_processing_consent')));
      await tester.pumpAndSettle();
      expect(auth.snapshot.hasProcessingAuthority, isTrue);
      expect((await store.currentReceipt())?.subjectUid, 'firebase-uid');

      await tester.tap(find.byKey(const Key('revoke_processing_consent')));
      await tester.pumpAndSettle();
      expect(auth.snapshot.consentGranted, isFalse);
      expect(await store.currentReceipt(), isNull);
      expect(gateway.didSignOut, isTrue);
    },
  );

  testWidgets('sign out does not silently revoke processing consent', (
    tester,
  ) async {
    final gateway = _Gateway(session, currentSession: session);
    final store = VolatileConsentStore();
    final auth = AuthController(gateway, consentStore: store);
    await auth.setConsent(true);
    await auth.grantProcessingConsent();

    await tester.pumpWidget(_controls(auth));
    await tester.tap(find.byKey(const Key('sign_out_firebase')));
    await tester.pumpAndSettle();

    expect(auth.snapshot.phase, AuthPhase.signedOut);
    expect((await store.currentReceipt())?.subjectUid, 'firebase-uid');
    expect(gateway.didSignOut, isTrue);
  });

  testWidgets('desktop completion recovers when session refresh fails', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final gateway = _Gateway(
      session,
      currentSession: session,
      failRefresh: true,
    );
    final auth = AuthController(gateway);
    await auth.restoreSession();
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopAuthScreen.forTesting(auth: auth, sessionId: 'session-id'),
      ),
    );

    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm this desktop'));
    await tester.pumpAndSettle();

    expect(find.text('Session refresh failed. Retry.'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.text('Session refresh failed. Retry.'))
          .getSemanticsData()
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Confirm this desktop'),
          )
          .onPressed,
      isNotNull,
    );
    semantics.dispose();
  });

  testWidgets('desktop completion ignores rapid repeated submission', (
    tester,
  ) async {
    final gateway = _Gateway(session, currentSession: session)
      ..refreshBarrier = Completer<void>();
    final auth = AuthController(gateway);
    await auth.restoreSession();
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopAuthScreen.forTesting(auth: auth, sessionId: 'session-id'),
      ),
    );
    await tester.enterText(find.byType(TextField).last, '123456');
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Confirm this desktop'),
    );

    button.onPressed!();
    button.onPressed!();
    await tester.pump();
    expect(gateway.refreshCalls, 1);

    gateway.refreshBarrier!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('production completion requires every applicable capability', (
    tester,
  ) async {
    final gateway = _Gateway(session, currentSession: session);
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('firebase-uid'),
    );
    await auth.restoreSession();
    var finished = false;
    final capabilities = _Capabilities({
      for (final capability in CoreCapability.values)
        capability: const CapabilityStatus(
          state: CapabilityState.granted,
          detail: 'Verified',
        ),
      CoreCapability.screenCapture: const CapabilityStatus(
        state: CapabilityState.actionRequired,
        detail: 'Screen Recording is not granted.',
      ),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProductionGate(
              configurationMessage: 'configured',
              auth: auth,
              capabilities: capabilities,
              onOpenPreview: () {},
              onFinish: () => finished = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(finished, isFalse);
    final permission = find.bySemanticsLabel(
      'I would like to see your screen so I can give relevant help.',
    );
    await tester.ensureVisible(permission);
    expect(
      tester
          .getSemantics(permission)
          .getSemanticsData()
          .flagsCollection
          .isButton,
      isTrue,
    );
    await tester.tap(permission);
    await tester.pumpAndSettle();
    expect(capabilities.requested, [CoreCapability.screenCapture]);
    expect(finished, isTrue);
  });

  testWidgets('granted permissions advance automatically once', (tester) async {
    final gateway = _Gateway(session, currentSession: session);
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('firebase-uid'),
    );
    await auth.restoreSession();
    var finished = false;
    final capabilities = _Capabilities({
      for (final capability in CoreCapability.values)
        capability: const CapabilityStatus(
          state: CapabilityState.granted,
          detail: 'Verified',
        ),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProductionGate(
              configurationMessage: 'configured',
              auth: auth,
              capabilities: capabilities,
              onOpenPreview: () {},
              onFinish: () => finished = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(find.text('Continue'), findsNothing);
  });

  testWidgets('permissions are rechecked automatically', (tester) async {
    final gateway = _Gateway(session, currentSession: session);
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('firebase-uid'),
    );
    await auth.restoreSession();
    var finished = false;
    final capabilities = _Capabilities({
      for (final capability in CoreCapability.values)
        capability: const CapabilityStatus(
          state: CapabilityState.granted,
          detail: 'Verified',
        ),
      CoreCapability.screenCapture: const CapabilityStatus(
        state: CapabilityState.actionRequired,
        detail: 'Grant screen recording',
      ),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ProductionGate(
          configurationMessage: 'configured',
          auth: auth,
          capabilities: capabilities,
          onOpenPreview: () {},
          onFinish: () => finished = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    capabilities.statuses[CoreCapability.screenCapture] =
        const CapabilityStatus(
          state: CapabilityState.granted,
          detail: 'Verified',
        );

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(capabilities.checkCalls, greaterThanOrEqualTo(2));
    expect(finished, isTrue);
  });

  testWidgets('duplicate capability requests are ignored while in flight', (
    tester,
  ) async {
    final gateway = _Gateway(session, currentSession: session);
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('firebase-uid'),
    );
    await auth.restoreSession();
    final capabilities = _Capabilities({
      for (final capability in CoreCapability.values)
        capability: const CapabilityStatus(
          state: CapabilityState.granted,
          detail: 'Verified',
        ),
      CoreCapability.screenCapture: const CapabilityStatus(
        state: CapabilityState.actionRequired,
        detail: 'Grant screen recording',
      ),
    })..requestBarrier = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProductionGate(
              configurationMessage: 'configured',
              auth: auth,
              capabilities: capabilities,
              onOpenPreview: () {},
              onFinish: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.text(
      'I would like to see your screen so I can give relevant help.',
    );
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.tap(row);
    await tester.pump();

    expect(capabilities.requested, [CoreCapability.screenCapture]);
    capabilities.requestBarrier!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('disposed pending request does not start another check', (
    tester,
  ) async {
    final gateway = _Gateway(session, currentSession: session);
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('firebase-uid'),
    );
    await auth.restoreSession();
    final capabilities = _Capabilities({
      for (final capability in CoreCapability.values)
        capability: const CapabilityStatus(
          state: CapabilityState.granted,
          detail: 'Verified',
        ),
      CoreCapability.screenCapture: const CapabilityStatus(
        state: CapabilityState.actionRequired,
        detail: 'Grant screen recording',
      ),
    })..requestBarrier = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProductionGate(
              configurationMessage: 'configured',
              auth: auth,
              capabilities: capabilities,
              onOpenPreview: () {},
              onFinish: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final workspace = find.text(
      'I would like to see your screen so I can give relevant help.',
    );
    await tester.ensureVisible(workspace);
    await tester.tap(workspace);
    await tester.pump();
    expect(capabilities.checkCalls, 1);

    await tester.pumpWidget(const SizedBox());
    capabilities.requestBarrier!.complete();
    await tester.pumpAndSettle();

    expect(capabilities.checkCalls, 1);
  });

  testWidgets('stale request error cannot replace a newer capability check', (
    tester,
  ) async {
    final gateway = _Gateway(session, currentSession: session);
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('firebase-uid'),
    );
    await auth.restoreSession();
    final capabilities =
        _Capabilities({
            for (final capability in CoreCapability.values)
              capability: const CapabilityStatus(
                state: CapabilityState.granted,
                detail: 'Verified',
              ),
            CoreCapability.screenCapture: const CapabilityStatus(
              state: CapabilityState.actionRequired,
              detail: 'Grant screen recording',
            ),
          })
          ..requestBarrier = Completer<void>()
          ..requestError = StateError('stale failure');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProductionGate(
              configurationMessage: 'configured',
              auth: auth,
              capabilities: capabilities,
              onOpenPreview: () {},
              onFinish: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final workspace = find.text(
      'I would like to see your screen so I can give relevant help.',
    );
    await tester.ensureVisible(workspace);
    await tester.tap(workspace);
    await tester.pump();
    capabilities.statuses[CoreCapability.screenCapture] =
        const CapabilityStatus(
          state: CapabilityState.granted,
          detail: 'Newer verified result',
        );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    capabilities.requestBarrier!.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('stale failure'), findsNothing);
  });

  test('mobile marks desktop capabilities not applicable', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final statuses = await PlatformDesktopCapabilityGateway().check();
    expect(statuses.values, hasLength(CoreCapability.values.length));
    expect(
      statuses.values.every(
        (status) =>
            status.state == CapabilityState.notApplicable && status.acceptable,
      ),
      isTrue,
    );
  });

  test(
    'mobile workspace verification and request do not touch storage',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final store = _TrackingWorkspaceStore();
      var pickerCalls = 0;
      final gateway = PlatformDesktopCapabilityGateway(
        workspaceRoots: store,
        directoryPicker: () async {
          pickerCalls += 1;
          return '/unsupported';
        },
      );

      expect(await gateway.verifiedWorkspaceRoot(), isNull);
      await gateway.request(CoreCapability.workspaceRoot);

      expect(store.readCalls, 0);
      expect(store.writeCalls, 0);
      expect(pickerCalls, 0);
    },
  );

  test('Windows requires only the probed microphone and workspace', () async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('omi/core_capabilities');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'check' ? {'microphone': true} : null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final statuses = await PlatformDesktopCapabilityGateway().check();
    expect(statuses[CoreCapability.accessibility]?.acceptable, isTrue);
    expect(statuses[CoreCapability.microphone]?.acceptable, isTrue);
    expect(statuses[CoreCapability.screenCapture]?.acceptable, isTrue);
    expect(statuses[CoreCapability.workspaceRoot]?.acceptable, isFalse);
    expect(
      statuses[CoreCapability.appData]?.state,
      anyOf(CapabilityState.granted, CapabilityState.error),
    );
    await PlatformDesktopCapabilityGateway().request(CoreCapability.microphone);
    expect(calls.map((call) => call.method), ['check', 'request']);
  });

  test('workspace selection persists canonically across recreation', () async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final directory = await Directory.systemTemp.createTemp('omi-workspace-');
    addTearDown(() => directory.delete(recursive: true));
    final store = PreferencesWorkspaceRootStore();
    final first = PlatformDesktopCapabilityGateway(
      workspaceRoots: store,
      directoryPicker: () async => directory.path,
    );

    await first.request(CoreCapability.workspaceRoot);
    final statuses = await PlatformDesktopCapabilityGateway(
      workspaceRoots: store,
    ).check();

    expect(
      statuses[CoreCapability.workspaceRoot]?.state,
      CapabilityState.granted,
    );
    expect(await store.read(), await directory.resolveSymbolicLinks());
  });

  test(
    'verified workspace returns the probed canonical path without rereading',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final directory = await Directory.systemTemp.createTemp('omi-workspace-');
      addTearDown(() => directory.delete(recursive: true));
      final canonical = await directory.resolveSymbolicLinks();
      final store = _TrackingWorkspaceStore(
        value: canonical,
        changeAfterRead: true,
      );

      final result = await PlatformDesktopCapabilityGateway(
        workspaceRoots: store,
      ).verifiedWorkspaceRoot();

      expect(result, canonical);
      expect(store.readCalls, 1);
    },
  );

  test('concurrent workspace requests share one picker operation', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final directory = await Directory.systemTemp.createTemp('omi-workspace-');
    addTearDown(() => directory.delete(recursive: true));
    final barrier = Completer<void>();
    var pickerCalls = 0;
    final gateway = PlatformDesktopCapabilityGateway(
      workspaceRoots: VolatileWorkspaceRootStore(),
      directoryPicker: () async {
        pickerCalls += 1;
        await barrier.future;
        return directory.path;
      },
    );

    final first = gateway.request(CoreCapability.workspaceRoot);
    final second = gateway.request(CoreCapability.workspaceRoot);
    barrier.complete();
    await Future.wait([first, second]);

    expect(pickerCalls, 1);
  });

  test(
    'missing persisted workspace is cleared and requires selection',
    () async {
      SharedPreferences.setMockInitialValues({});
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final directory = await Directory.systemTemp.createTemp('omi-workspace-');
      final store = PreferencesWorkspaceRootStore();
      await store.write(await directory.resolveSymbolicLinks());
      await directory.delete(recursive: true);

      final statuses = await PlatformDesktopCapabilityGateway(
        workspaceRoots: store,
      ).check();

      expect(
        statuses[CoreCapability.workspaceRoot]?.state,
        CapabilityState.actionRequired,
      );
      expect(await store.read(), isNull);
    },
  );

  test('workspace clear failure does not mask verification failure', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final store = _TrackingWorkspaceStore(
      value: '/definitely/missing/omi-workspace',
      failClear: true,
    );
    final gateway = PlatformDesktopCapabilityGateway(workspaceRoots: store);

    final statuses = await gateway.check();

    expect(
      statuses[CoreCapability.workspaceRoot]?.state,
      CapabilityState.actionRequired,
    );
    expect(await gateway.verifiedWorkspaceRoot(), isNull);
    expect(store.clearCalls, 2);
  });
}

ProcessingConsentReceipt _receipt(String uid) =>
    ProcessingConsentReceipt.current(
      subjectUid: uid,
      acceptedAt: DateTime.utc(2026, 7, 21),
    );

Widget _controls(AuthController auth) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: ListenableBuilder(
      listenable: auth,
      builder: (context, _) => ListView(
        children: [
          ProcessingConsentGate(auth: auth),
          AuthenticationGate(auth: auth, configurationMessage: 'configured'),
        ],
      ),
    ),
  ),
);

final class _Gateway implements AuthGateway {
  _Gateway(this.session, {this.currentSession, this.failRefresh = false});

  final AuthSession session;
  @override
  AuthSession? currentSession;
  bool didSignOut = false;
  final bool failRefresh;
  Completer<void>? refreshBarrier;
  int refreshCalls = 0;

  @override
  AuthFailure? get configurationFailure => null;

  @override
  bool get isConfigured => true;

  @override
  Stream<AuthSession?> get sessionChanges => const Stream.empty();

  @override
  bool get supportsPhoneOtp => true;

  @override
  bool get supportsDesktopBrowserHandoff => false;

  @override
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) async => session;

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) async =>
      const PhoneOtpChallenge(verificationId: 'challenge');

  @override
  Future<AuthSession?> refreshSession() async {
    refreshCalls += 1;
    await refreshBarrier?.future;
    if (failRefresh) {
      throw const AuthOperationException(
        AuthFailure(AuthErrorCode.network, 'Session refresh failed. Retry.'),
      );
    }
    return currentSession;
  }

  @override
  Future<AuthSession?> restoreSession() async => currentSession;

  @override
  Future<AuthSession> signIn(AuthProvider provider) async =>
      currentSession = session;

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) async => currentSession = session;

  @override
  Future<void> signOut() async {
    didSignOut = true;
    currentSession = null;
  }
}

final class _Capabilities implements DesktopCapabilityGateway {
  _Capabilities(this.statuses);

  final Map<CoreCapability, CapabilityStatus> statuses;
  final requested = <CoreCapability>[];
  Completer<void>? requestBarrier;
  Object? requestError;
  int checkCalls = 0;

  @override
  Future<Map<CoreCapability, CapabilityStatus>> check() async {
    checkCalls += 1;
    return statuses;
  }

  @override
  Future<void> request(CoreCapability capability) async {
    requested.add(capability);
    await requestBarrier?.future;
    if (requestError case final error?) throw error;
    statuses[capability] = const CapabilityStatus(
      state: CapabilityState.granted,
      detail: 'Verified',
    );
  }
}

final class _TrackingWorkspaceStore implements WorkspaceRootStore {
  _TrackingWorkspaceStore({
    this.value,
    this.changeAfterRead = false,
    this.failClear = false,
  });

  String? value;
  final bool changeAfterRead;
  final bool failClear;
  int readCalls = 0;
  int writeCalls = 0;
  int clearCalls = 0;

  @override
  Future<String?> read() async {
    readCalls += 1;
    final result = value;
    if (changeAfterRead) value = null;
    return result;
  }

  @override
  Future<void> write(String path) async {
    writeCalls += 1;
    value = path;
  }

  @override
  Future<void> clear() async {
    clearCalls += 1;
    if (failClear) throw StateError('clear failed');
    value = null;
  }
}
