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

      controller.setConsent(true);
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

    controller.setConsent(true);
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
    final controller = AuthController(gateway)..setConsent(true);

    await controller.signIn(AuthProvider.google);

    expect(controller.snapshot.phase, AuthPhase.failed);
    expect(controller.snapshot.failure?.code, AuthErrorCode.cancelled);
    expect(controller.snapshot.session, isNull);
  });

  test('sign out clears the local session boundary', () async {
    final gateway = _FakeAuthGateway(session, initialSession: session);
    final controller = AuthController(gateway)..setConsent(true);

    expect(controller.snapshot.phase, AuthPhase.signedIn);
    await controller.signOut();

    expect(controller.snapshot.phase, AuthPhase.signedOut);
    expect(controller.snapshot.session, isNull);
    expect(gateway.didSignOut, isTrue);
  });
}

final class _FakeAuthGateway implements AuthGateway {
  _FakeAuthGateway(this.session, {this.initialSession});

  final AuthSession session;
  final AuthSession? initialSession;
  AuthFailure? failure;
  String? requestedPhone;
  String? confirmedCode;
  bool didSignOut = false;

  @override
  bool get isConfigured => true;

  @override
  AuthSession? get currentSession => initialSession;

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
    return const PhoneOtpChallenge(verificationId: 'verification-id');
  }

  @override
  Future<AuthSession> signIn(AuthProvider provider) async => _result(session);

  @override
  Future<void> signOut() async {
    didSignOut = true;
  }

  AuthSession _result(AuthSession value) {
    final currentFailure = failure;
    if (currentFailure != null) throw AuthOperationException(currentFailure);
    return value;
  }
}
