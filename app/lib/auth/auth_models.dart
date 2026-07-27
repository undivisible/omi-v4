import 'consent_store.dart';

enum AuthProvider { phone, google, apple }

enum AuthPhase {
  /// The stored session has not been looked for yet. Distinct from
  /// [signedOut], which is an answer: this one means there is no answer.
  /// Screens that branch on being signed in have to wait this out, or they
  /// render the signed-out branch and then swap it a beat later.
  restoring,

  signedOut,
  requestingOtp,
  awaitingOtp,
  signingIn,
  signedIn,
  signingOut,
  unavailable,
  failed,
}

enum AuthErrorCode {
  consentRequired,
  invalidPhoneNumber,
  invalidOtp,
  otpExpired,
  cancelled,
  rateLimited,
  configurationMissing,
  unsupportedPlatform,
  consentPersistence,
  network,
  unknown,
}

final class AuthSession {
  const AuthSession({
    required this.uid,
    required this.idToken,
    required this.expiresAt,
    this.phoneNumber,
    this.email,
    this.displayName,
  });

  final String uid;
  final String idToken;
  final DateTime expiresAt;
  final String? phoneNumber;
  final String? email;
  final String? displayName;
}

final class PhoneOtpChallenge {
  const PhoneOtpChallenge({
    required this.verificationId,
    this.resendToken,
    this.completedSession,
  });

  final String verificationId;
  final int? resendToken;
  final AuthSession? completedSession;
}

final class AuthFailure {
  const AuthFailure(this.code, this.message);

  final AuthErrorCode code;
  final String message;
}

final class AuthSnapshot {
  const AuthSnapshot({
    required this.phase,
    required this.consentGranted,
    this.session,
    this.challenge,
    this.failure,
    this.processingConsent,
  });

  const AuthSnapshot.initial()
    : phase = AuthPhase.restoring,
      consentGranted = false,
      session = null,
      challenge = null,
      failure = null,
      processingConsent = null;

  final AuthPhase phase;
  final bool consentGranted;
  final AuthSession? session;
  final PhoneOtpChallenge? challenge;
  final AuthFailure? failure;
  final ProcessingConsentReceipt? processingConsent;

  bool get hasProcessingAuthority =>
      session != null && processingConsent?.authorizes(session!.uid) == true;

  /// Whether the answer is still outstanding. Nothing should decide what to
  /// show the user while this is true.
  bool get settling => phase == AuthPhase.restoring;
}
