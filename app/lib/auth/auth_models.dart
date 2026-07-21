enum AuthProvider { phone, google, apple }

enum AuthPhase {
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
  const PhoneOtpChallenge({required this.verificationId, this.resendToken});

  final String verificationId;
  final int? resendToken;
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
  });

  const AuthSnapshot.initial()
    : phase = AuthPhase.signedOut,
      consentGranted = false,
      session = null,
      challenge = null,
      failure = null;

  final AuthPhase phase;
  final bool consentGranted;
  final AuthSession? session;
  final PhoneOtpChallenge? challenge;
  final AuthFailure? failure;
}
