import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auth_gateway.dart';
import 'auth_models.dart';
import 'consent_store.dart';

final class AuthController extends ChangeNotifier {
  AuthController(this._gateway, {ConsentStore? consentStore})
    : _consentStore = consentStore ?? VolatileConsentStore(),
      _snapshot = _gateway.isConfigured
          ? const AuthSnapshot.initial()
          : AuthSnapshot(
              phase: AuthPhase.unavailable,
              consentGranted: false,
              failure: _gateway.configurationFailure,
            );

  final AuthGateway _gateway;
  final ConsentStore _consentStore;
  AuthSnapshot _snapshot;
  StreamSubscription<AuthSession?>? _sessionSubscription;
  Future<void> _sessionSync = Future.value();
  bool _disposed = false;
  String? _desktopConfirmationCode;

  AuthSnapshot get snapshot => _snapshot;
  String? get desktopConfirmationCode => _desktopConfirmationCode;

  bool get supportsPhoneOtp => _gateway.supportsPhoneOtp;

  bool get supportsDesktopBrowserHandoff =>
      _gateway.supportsDesktopBrowserHandoff;

  Future<void> restoreSession() async {
    if (!_gateway.isConfigured) return;
    try {
      _observeSessions();
      final session = await _gateway.restoreSession();
      if (session != null) {
        _authenticated(
          session,
          consentGranted: true,
          processingConsent: await _receiptFor(session.uid),
        );
      } else {
        _set(
          const AuthSnapshot(phase: AuthPhase.signedOut, consentGranted: false),
        );
      }
    } on AuthGatewayException catch (error) {
      _fail(error.failure.code, error.failure.message);
    } catch (_) {
      _fail(AuthErrorCode.unknown, 'Could not restore authentication');
    }
  }

  void _observeSessions() {
    _sessionSubscription ??= _gateway.sessionChanges.listen((session) {
      _sessionSync = _sessionSync
          .then<void>((_) {}, onError: (_, _) {})
          .then((_) => _applyObservedSession(session))
          .then<void>((_) {}, onError: _observedSessionError);
    }, onError: _observedSessionError);
  }

  void _observedSessionError(Object error, StackTrace stackTrace) {
    if (error case AuthGatewayException(:final failure)) {
      _fail(failure.code, failure.message);
    } else {
      _fail(AuthErrorCode.network, 'Authentication state changed');
    }
  }

  Future<void> _applyObservedSession(AuthSession? session) async {
    if (_disposed) return;
    if (session == null) {
      _set(
        const AuthSnapshot(phase: AuthPhase.signedOut, consentGranted: false),
      );
    } else {
      _authenticated(
        session,
        consentGranted: true,
        processingConsent: await _receiptFor(session.uid),
      );
    }
  }

  Future<AuthSession?> validSession() async {
    if (!_gateway.isConfigured ||
        _snapshot.phase != AuthPhase.signedIn ||
        !_snapshot.hasProcessingAuthority) {
      return null;
    }
    try {
      final receipt = await _receiptFor(_snapshot.session!.uid);
      if (receipt == null) {
        _set(
          AuthSnapshot(
            phase: AuthPhase.signedIn,
            consentGranted: _snapshot.consentGranted,
            session: _snapshot.session,
          ),
        );
        return null;
      }
      final session = await _gateway.refreshSession();
      if (session == null) {
        _set(
          AuthSnapshot(
            phase: AuthPhase.signedOut,
            consentGranted: _snapshot.consentGranted,
          ),
        );
        return null;
      }
      if (!receipt.authorizes(session.uid)) {
        _set(
          AuthSnapshot(
            phase: AuthPhase.signedIn,
            consentGranted: true,
            session: session,
          ),
        );
        return null;
      }
      _authenticated(session, consentGranted: true, processingConsent: receipt);
      return session;
    } on AuthGatewayException catch (error) {
      _fail(error.failure.code, error.failure.message);
      return null;
    } catch (_) {
      _fail(AuthErrorCode.network, 'Could not refresh authentication');
      return null;
    }
  }

  Future<void> setConsent(bool granted) async {
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
        processingConsent: granted && session != null
            ? _snapshot.processingConsent
            : null,
        failure: _gateway.isConfigured ? null : _gateway.configurationFailure,
      ),
    );
  }

  Future<void> grantProcessingConsent({DateTime? acceptedAt}) async {
    final session = _snapshot.session;
    if (_snapshot.phase != AuthPhase.signedIn || session == null) {
      _fail(
        AuthErrorCode.consentRequired,
        'Sign in before granting processing consent',
      );
      return;
    }
    final receipt = ProcessingConsentReceipt.current(
      subjectUid: session.uid,
      acceptedAt: acceptedAt ?? DateTime.now(),
    );
    try {
      await _consentStore.save(receipt);
      _set(
        AuthSnapshot(
          phase: AuthPhase.signedIn,
          consentGranted: _snapshot.consentGranted,
          session: session,
          processingConsent: receipt,
        ),
      );
    } on ConsentPersistenceException catch (error) {
      _fail(AuthErrorCode.consentPersistence, error.message);
    } catch (_) {
      _fail(
        AuthErrorCode.consentPersistence,
        'Processing consent could not be saved',
      );
    }
  }

  Future<void> revokeProcessingConsent() async {
    _set(
      AuthSnapshot(
        phase: _gateway.isConfigured
            ? AuthPhase.signingOut
            : AuthPhase.unavailable,
        consentGranted: false,
        failure: _gateway.isConfigured ? null : _gateway.configurationFailure,
      ),
    );
    AuthFailure? failure;
    try {
      await _consentStore.revoke();
    } on ConsentPersistenceException catch (error) {
      failure = AuthFailure(AuthErrorCode.consentPersistence, error.message);
    } catch (_) {
      failure = const AuthFailure(
        AuthErrorCode.consentPersistence,
        'Processing consent could not be revoked',
      );
    }
    if (_gateway.isConfigured) {
      try {
        await _gateway.signOut();
      } on AuthGatewayException catch (error) {
        failure ??= error.failure;
      } catch (_) {
        failure ??= const AuthFailure(
          AuthErrorCode.unknown,
          'Could not clear authentication',
        );
      }
    }
    if (failure case final value?) {
      _fail(value.code, value.message, consentGranted: false);
    } else {
      _set(const AuthSnapshot.initial());
    }
  }

  Future<void> requestPhoneOtp(String phoneNumber) async {
    if (!_canAuthenticate()) return;
    if (!_gateway.supportsPhoneOtp) {
      _fail(
        AuthErrorCode.unsupportedPlatform,
        'Phone sign-in is not supported on this platform',
      );
      return;
    }
    final phone = phoneNumber.trim();
    if (phone.isEmpty) {
      _fail(AuthErrorCode.invalidPhoneNumber, 'Phone number is required');
      return;
    }
    final consentGranted = _snapshot.consentGranted;
    _set(
      AuthSnapshot(
        phase: AuthPhase.requestingOtp,
        consentGranted: consentGranted,
      ),
    );
    try {
      final challenge = await _gateway.requestPhoneOtp(phone);
      if (challenge.completedSession case final session?) {
        _authenticated(session, consentGranted: consentGranted);
        return;
      }
      _set(
        AuthSnapshot(
          phase: AuthPhase.awaitingOtp,
          consentGranted: consentGranted,
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
        consentGranted: _snapshot.consentGranted,
        challenge: challenge,
      ),
    );
    try {
      _authenticated(
        await _gateway.confirmPhoneOtp(challenge: challenge, code: code.trim()),
        consentGranted: _snapshot.consentGranted,
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
    final consentGranted = _snapshot.consentGranted;
    _set(
      AuthSnapshot(phase: AuthPhase.signingIn, consentGranted: consentGranted),
    );
    try {
      _authenticated(
        await _gateway.signIn(provider),
        consentGranted: consentGranted,
      );
    } on AuthGatewayException catch (error) {
      _fail(error.failure.code, error.failure.message);
    } catch (_) {
      _fail(AuthErrorCode.unknown, 'Authentication failed');
    }
  }

  Future<void> signInWithDesktopBrowser() async {
    if (!_canAuthenticate()) return;
    _desktopConfirmationCode = null;
    _set(AuthSnapshot(phase: AuthPhase.signingIn, consentGranted: true));
    try {
      _authenticated(
        await _gateway.signInWithDesktopBrowser(
          onConfirmationCode: (code) {
            _desktopConfirmationCode = code;
            notifyListeners();
          },
        ),
        consentGranted: true,
      );
    } on AuthGatewayException catch (error) {
      _fail(error.failure.code, error.failure.message);
    } catch (_) {
      _fail(AuthErrorCode.network, 'Desktop sign-in failed');
    }
  }

  Future<void> signOut() async {
    if (!_gateway.isConfigured || _snapshot.phase == AuthPhase.signingOut) {
      return;
    }
    _set(
      const AuthSnapshot(phase: AuthPhase.signingOut, consentGranted: false),
    );
    try {
      await _gateway.signOut();
      _set(const AuthSnapshot.initial());
    } on AuthGatewayException catch (error) {
      _fail(error.failure.code, error.failure.message, consentGranted: false);
    } catch (_) {
      _fail(AuthErrorCode.unknown, 'Sign out failed', consentGranted: false);
    }
  }

  Future<AuthSession?> handoffSession() async {
    final current = _snapshot.session;
    if (_snapshot.phase != AuthPhase.signedIn || current == null) return null;
    final refreshed = await _gateway.refreshSession();
    return refreshed?.uid == current.uid ? refreshed : null;
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

  Future<ProcessingConsentReceipt?> _receiptFor(String uid) async {
    try {
      final receipt = await _consentStore.currentReceipt();
      return receipt?.authorizes(uid) == true ? receipt : null;
    } on ConsentPersistenceException {
      return null;
    } catch (_) {
      return null;
    }
  }

  void _authenticated(
    AuthSession session, {
    required bool consentGranted,
    ProcessingConsentReceipt? processingConsent,
  }) {
    if (session.uid.isEmpty || session.idToken.isEmpty) {
      _fail(AuthErrorCode.unknown, 'Firebase returned an invalid session');
      return;
    }
    _set(
      AuthSnapshot(
        phase: AuthPhase.signedIn,
        consentGranted: consentGranted,
        session: session,
        processingConsent: processingConsent?.authorizes(session.uid) == true
            ? processingConsent
            : null,
      ),
    );
  }

  void _fail(
    AuthErrorCode code,
    String message, {
    PhoneOtpChallenge? challenge,
    bool? consentGranted,
  }) {
    _set(
      AuthSnapshot(
        phase: code == AuthErrorCode.configurationMissing
            ? AuthPhase.unavailable
            : AuthPhase.failed,
        consentGranted: consentGranted ?? _snapshot.consentGranted,
        challenge: challenge,
        failure: AuthFailure(code, message),
      ),
    );
  }

  void _set(AuthSnapshot next) {
    if (_disposed) return;
    _snapshot = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sessionSubscription?.cancel());
    super.dispose();
  }
}
