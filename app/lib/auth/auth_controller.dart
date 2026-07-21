import 'package:flutter/foundation.dart';

import 'auth_gateway.dart';
import 'auth_models.dart';

final class AuthController extends ChangeNotifier {
  AuthController(this._gateway)
    : _snapshot = _gateway.isConfigured
          ? const AuthSnapshot.initial()
          : const AuthSnapshot(
              phase: AuthPhase.unavailable,
              consentGranted: false,
              failure: AuthFailure(
                AuthErrorCode.configurationMissing,
                'Firebase configuration is missing',
              ),
            );

  final AuthGateway _gateway;
  AuthSnapshot _snapshot;

  AuthSnapshot get snapshot => _snapshot;

  void setConsent(bool granted) {
    final session = granted ? _gateway.currentSession : null;
    _set(
      AuthSnapshot(
        phase: !_gateway.isConfigured
            ? AuthPhase.unavailable
            : session == null
            ? AuthPhase.signedOut
            : AuthPhase.signedIn,
        consentGranted: granted,
        session: session,
        failure: _gateway.isConfigured
            ? null
            : const AuthFailure(
                AuthErrorCode.configurationMissing,
                'Firebase configuration is missing',
              ),
      ),
    );
  }

  Future<void> requestPhoneOtp(String phoneNumber) async {
    if (!_canAuthenticate()) return;
    final phone = phoneNumber.trim();
    if (phone.isEmpty) {
      _fail(AuthErrorCode.invalidPhoneNumber, 'Phone number is required');
      return;
    }
    _set(AuthSnapshot(phase: AuthPhase.requestingOtp, consentGranted: true));
    try {
      final challenge = await _gateway.requestPhoneOtp(phone);
      _set(
        AuthSnapshot(
          phase: AuthPhase.awaitingOtp,
          consentGranted: true,
          challenge: challenge,
        ),
      );
    } on AuthGatewayException catch (error) {
      _fail(error.failure.code, error.failure.message);
    } catch (_) {
      _fail(AuthErrorCode.unknown, 'Authentication failed');
    }
  }

  Future<void> confirmPhoneOtp(String code) async {
    if (!_canAuthenticate()) return;
    final challenge = _snapshot.challenge;
    if (challenge == null || code.trim().isEmpty) {
      _fail(AuthErrorCode.invalidOtp, 'Verification code is required');
      return;
    }
    _set(
      AuthSnapshot(
        phase: AuthPhase.signingIn,
        consentGranted: true,
        challenge: challenge,
      ),
    );
    try {
      _authenticated(
        await _gateway.confirmPhoneOtp(challenge: challenge, code: code.trim()),
      );
    } on AuthGatewayException catch (error) {
      _fail(error.failure.code, error.failure.message, challenge: challenge);
    } catch (_) {
      _fail(
        AuthErrorCode.unknown,
        'Authentication failed',
        challenge: challenge,
      );
    }
  }

  Future<void> signIn(AuthProvider provider) async {
    if (!_canAuthenticate()) return;
    if (provider == AuthProvider.phone) {
      _fail(AuthErrorCode.invalidPhoneNumber, 'Phone sign-in requires an OTP');
      return;
    }
    _set(AuthSnapshot(phase: AuthPhase.signingIn, consentGranted: true));
    try {
      _authenticated(await _gateway.signIn(provider));
    } on AuthGatewayException catch (error) {
      _fail(error.failure.code, error.failure.message);
    } catch (_) {
      _fail(AuthErrorCode.unknown, 'Authentication failed');
    }
  }

  Future<void> signOut() async {
    if (!_gateway.isConfigured || _snapshot.phase == AuthPhase.signingOut) {
      return;
    }
    _set(
      AuthSnapshot(
        phase: AuthPhase.signingOut,
        consentGranted: _snapshot.consentGranted,
        session: _snapshot.session,
      ),
    );
    try {
      await _gateway.signOut();
      _set(
        AuthSnapshot(
          phase: AuthPhase.signedOut,
          consentGranted: _snapshot.consentGranted,
        ),
      );
    } on AuthGatewayException catch (error) {
      _fail(error.failure.code, error.failure.message);
    } catch (_) {
      _fail(AuthErrorCode.unknown, 'Sign out failed');
    }
  }

  bool _canAuthenticate() {
    if (!_gateway.isConfigured) {
      _fail(
        AuthErrorCode.configurationMissing,
        'Firebase configuration is missing',
      );
      return false;
    }
    if (!_snapshot.consentGranted) {
      _fail(
        AuthErrorCode.consentRequired,
        'Consent is required before signing in',
      );
      return false;
    }
    if ({
      AuthPhase.requestingOtp,
      AuthPhase.signingIn,
      AuthPhase.signingOut,
    }.contains(_snapshot.phase)) {
      return false;
    }
    return true;
  }

  void _authenticated(AuthSession session) {
    if (session.uid.isEmpty || session.idToken.isEmpty) {
      _fail(AuthErrorCode.unknown, 'Firebase returned an invalid session');
      return;
    }
    _set(
      AuthSnapshot(
        phase: AuthPhase.signedIn,
        consentGranted: true,
        session: session,
      ),
    );
  }

  void _fail(
    AuthErrorCode code,
    String message, {
    PhoneOtpChallenge? challenge,
  }) {
    _set(
      AuthSnapshot(
        phase: code == AuthErrorCode.configurationMissing
            ? AuthPhase.unavailable
            : AuthPhase.failed,
        consentGranted: _snapshot.consentGranted,
        challenge: challenge,
        failure: AuthFailure(code, message),
      ),
    );
  }

  void _set(AuthSnapshot next) {
    _snapshot = next;
    notifyListeners();
  }
}
