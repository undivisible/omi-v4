import 'package:flutter_test/flutter_test.dart';
import 'package:omi/auth/auth.dart';

void main() {
  final session = AuthSession(
    uid: 'firebase-uid',
    idToken: 'firebase-id-token',
    expiresAt: DateTime.utc(2030),
  );

  test(
    'missing Firebase configuration is explicit and blocks sign-in',
    () async {
      final controller = AuthController(const UnconfiguredAuthGateway());

      expect(controller.snapshot.phase, AuthPhase.unavailable);
      expect(
        controller.snapshot.failure?.code,
        AuthErrorCode.configurationMissing,
      );

      await controller.setConsent(true);
      await controller.requestPhoneOtp('+15555550123');

      expect(controller.snapshot.phase, AuthPhase.unavailable);
      expect(
        controller.snapshot.failure?.code,
        AuthErrorCode.configurationMissing,
      );
    },
  );

  test('phone OTP requires consent and produces a Firebase session', () async {
    final gateway = _FakeAuthGateway(session);
    final controller = AuthController(gateway);

    await controller.requestPhoneOtp('+15555550123');
    expect(controller.snapshot.failure?.code, AuthErrorCode.consentRequired);

    await controller.setConsent(true);
    await controller.requestPhoneOtp(' +15555550123 ');
    expect(controller.snapshot.phase, AuthPhase.awaitingOtp);
    expect(gateway.requestedPhone, '+15555550123');

    await controller.confirmPhoneOtp(' 123456 ');
    expect(controller.snapshot.phase, AuthPhase.signedIn);
    expect(controller.snapshot.session?.uid, 'firebase-uid');
    expect(controller.snapshot.session?.idToken, 'firebase-id-token');
    expect(gateway.confirmedCode, '123456');
  });

  test('OAuth failure remains typed and does not create a session', () async {
    final gateway = _FakeAuthGateway(session)
      ..failure = const AuthFailure(
        AuthErrorCode.cancelled,
        'Sign-in cancelled',
      );
    final controller = AuthController(gateway);
    await controller.setConsent(true);

    await controller.signIn(AuthProvider.google);

    expect(controller.snapshot.phase, AuthPhase.failed);
    expect(controller.snapshot.failure?.code, AuthErrorCode.cancelled);
    expect(controller.snapshot.session, isNull);
  });

  test('Apple unsupported failure remains typed', () async {
    final gateway = _FakeAuthGateway(session)
      ..failure = const AuthFailure(
        AuthErrorCode.unsupportedPlatform,
        'Apple sign-in is unsupported',
      );
    final controller = AuthController(gateway);
    await controller.setConsent(true);

    await controller.signIn(AuthProvider.apple);

    expect(controller.snapshot.phase, AuthPhase.failed);
    expect(
      controller.snapshot.failure?.code,
      AuthErrorCode.unsupportedPlatform,
    );
    expect(controller.snapshot.session, isNull);
  });

  test('Google and Apple OAuth produce Firebase sessions', () async {
    for (final provider in [AuthProvider.google, AuthProvider.apple]) {
      final controller = AuthController(_FakeAuthGateway(session));
      await controller.setConsent(true);

      await controller.signIn(provider);

      expect(controller.snapshot.phase, AuthPhase.signedIn);
      expect(controller.snapshot.session?.uid, 'firebase-uid');
    }
  });

  test(
    'unsupported desktop phone OTP fails before invoking Firebase',
    () async {
      final gateway = _FakeAuthGateway(session, supportsPhoneOtp: false);
      final controller = AuthController(gateway);
      await controller.setConsent(true);

      await controller.requestPhoneOtp('+15555550123');

      expect(
        controller.snapshot.failure?.code,
        AuthErrorCode.unsupportedPlatform,
      );
      expect(gateway.requestedPhone, isNull);
    },
  );

  test('sign out clears the local session boundary', () async {
    final gateway = _FakeAuthGateway(session, initialSession: session);
    final controller = AuthController(gateway);
    await controller.setConsent(true);

    expect(controller.snapshot.phase, AuthPhase.signedIn);
    await controller.signOut();

    expect(controller.snapshot.phase, AuthPhase.signedOut);
    expect(controller.snapshot.session, isNull);
    expect(gateway.didSignOut, isTrue);
  });

  test('logout errors remain typed and clear the local token', () async {
    final gateway = _FakeAuthGateway(session, initialSession: session);
    final controller = AuthController(gateway);
    await controller.setConsent(true);
    gateway.failure = const AuthFailure(
      AuthErrorCode.network,
      'Could not reach Firebase',
    );

    await controller.signOut();

    expect(controller.snapshot.phase, AuthPhase.failed);
    expect(controller.snapshot.failure?.code, AuthErrorCode.network);
    expect(controller.snapshot.session, isNull);
  });

  test(
    'restores and refreshes only with a versioned consent receipt',
    () async {
      final gateway = _FakeAuthGateway(session, initialSession: session);
      final consent = VolatileConsentStore();
      await consent.save(
        ProcessingConsentReceipt.current(
          subjectUid: session.uid,
          acceptedAt: DateTime.utc(2026, 7, 21),
        ),
      );
      final controller = AuthController(gateway, consentStore: consent);

      await controller.restoreSession();
      final refreshed = await controller.validSession();

      expect(controller.snapshot.phase, AuthPhase.signedIn);
      expect(refreshed?.idToken, 'firebase-id-token');
      expect(gateway.refreshCalls, 1);
    },
  );

  test('persisted Firebase session cannot manufacture consent', () async {
    final gateway = _FakeAuthGateway(session, initialSession: session);
    final controller = AuthController(
      gateway,
      consentStore: VolatileConsentStore(),
    );

    await controller.restoreSession();

    expect(controller.snapshot.phase, AuthPhase.signedIn);
    expect(controller.snapshot.session?.uid, session.uid);
    expect(controller.snapshot.hasProcessingAuthority, isFalse);
    expect(gateway.didSignOut, isFalse);
  });

  test('revoking consent signs out and blocks token refresh', () async {
    final gateway = _FakeAuthGateway(session, initialSession: session);
    final consent = VolatileConsentStore();
    final controller = AuthController(gateway, consentStore: consent);
    await controller.setConsent(true);
    await controller.grantProcessingConsent(
      acceptedAt: DateTime.utc(2026, 7, 21),
    );
    await controller.revokeProcessingConsent();

    final refreshed = await controller.validSession();

    expect(refreshed, isNull);
    expect(controller.snapshot.consentGranted, isFalse);
    expect(gateway.didSignOut, isTrue);
    expect(gateway.refreshCalls, 0);
  });

  test(
    'account switch during refresh cannot reuse another subject receipt',
    () async {
      final gateway = _FakeAuthGateway(session, initialSession: session);
      final consent = VolatileConsentStore()
        ..receipt = ProcessingConsentReceipt.current(
          subjectUid: session.uid,
          acceptedAt: DateTime.utc(2026, 7, 21),
        );
      final controller = AuthController(gateway, consentStore: consent);
      await controller.restoreSession();
      gateway.initialSession = AuthSession(
        uid: 'other-user',
        idToken: 'other-token',
        expiresAt: DateTime.utc(2030),
      );

      expect(await controller.validSession(), isNull);
      expect(controller.snapshot.session?.uid, 'other-user');
      expect(controller.snapshot.hasProcessingAuthority, isFalse);
    },
  );

  test(
    'consent persistence failures never create or restore authority',
    () async {
      final gateway = _FakeAuthGateway(session, initialSession: session);
      final controller = AuthController(
        gateway,
        consentStore: const _FailingConsentStore(),
      );
      await controller.setConsent(true);

      await controller.grantProcessingConsent();

      expect(controller.snapshot.hasProcessingAuthority, isFalse);
      expect(
        controller.snapshot.failure?.code,
        AuthErrorCode.consentPersistence,
      );
    },
  );

  test('automatic phone verification signs in without an OTP', () async {
    final gateway = _FakeAuthGateway(session)
      ..challenge = PhoneOtpChallenge(
        verificationId: 'automatic',
        completedSession: session,
      );
    final controller = AuthController(gateway);
    await controller.setConsent(true);

    await controller.requestPhoneOtp('+15555550123');

    expect(controller.snapshot.phase, AuthPhase.signedIn);
    expect(controller.snapshot.session?.uid, 'firebase-uid');
  });

  test('desktop browser handoff produces a Firebase session', () async {
    final gateway = _FakeAuthGateway(
      session,
      supportsPhoneOtp: false,
      supportsDesktopBrowserHandoff: true,
    );
    final controller = AuthController(gateway);
    await controller.setConsent(true);

    await controller.signInWithDesktopBrowser();

    expect(controller.snapshot.phase, AuthPhase.signedIn);
    expect(controller.snapshot.session?.uid, 'firebase-uid');
  });
}

final class _FailingConsentStore implements ConsentStore {
  const _FailingConsentStore();

  @override
  Future<ProcessingConsentReceipt?> currentReceipt() async => null;

  @override
  Future<void> revoke() => throw const ConsentPersistenceException('failed');

  @override
  Future<void> save(ProcessingConsentReceipt receipt) =>
      throw const ConsentPersistenceException('failed');
}

final class _FakeAuthGateway implements AuthGateway {
  _FakeAuthGateway(
    this.session, {
    this.initialSession,
    this.supportsPhoneOtp = true,
    this.supportsDesktopBrowserHandoff = false,
  });

  final AuthSession session;
  AuthSession? initialSession;
  AuthFailure? failure;
  String? requestedPhone;
  String? confirmedCode;
  bool didSignOut = false;
  int refreshCalls = 0;
  PhoneOtpChallenge challenge = const PhoneOtpChallenge(
    verificationId: 'verification-id',
  );

  @override
  bool get isConfigured => true;

  @override
  AuthFailure? get configurationFailure => null;

  @override
  final bool supportsPhoneOtp;

  @override
  final bool supportsDesktopBrowserHandoff;

  @override
  AuthSession? get currentSession => initialSession;

  @override
  Stream<AuthSession?> get sessionChanges => const Stream.empty();

  @override
  Future<AuthSession?> restoreSession() async => initialSession;

  @override
  Future<AuthSession?> refreshSession() async {
    refreshCalls += 1;
    return currentSession ?? session;
  }

  @override
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) async {
    confirmedCode = code;
    return _result(session);
  }

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) async {
    requestedPhone = phoneNumber;
    final currentFailure = failure;
    if (currentFailure != null) throw AuthOperationException(currentFailure);
    return challenge;
  }

  @override
  Future<AuthSession> signIn(AuthProvider provider) async => _result(session);

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) async {
    onConfirmationCode('123456');
    return _result(session);
  }

  @override
  Future<void> signOut() async {
    final currentFailure = failure;
    if (currentFailure != null) throw AuthOperationException(currentFailure);
    didSignOut = true;
    initialSession = null;
  }

  AuthSession _result(AuthSession value) {
    final currentFailure = failure;
    if (currentFailure != null) throw AuthOperationException(currentFailure);
    return value;
  }
}
