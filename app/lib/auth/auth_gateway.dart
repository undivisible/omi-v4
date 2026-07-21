import 'auth_models.dart';

sealed class AuthGatewayException implements Exception {
  const AuthGatewayException(this.failure);

  final AuthFailure failure;
}

final class AuthConfigurationException extends AuthGatewayException {
  AuthConfigurationException([
    String message = 'Firebase configuration is missing',
  ]) : super(AuthFailure(AuthErrorCode.configurationMissing, message));
}

final class AuthOperationException extends AuthGatewayException {
  const AuthOperationException(super.failure);
}

abstract interface class AuthGateway {
  bool get isConfigured;

  AuthFailure? get configurationFailure;

  bool get supportsPhoneOtp;

  bool get supportsDesktopBrowserHandoff;

  AuthSession? get currentSession;

  Stream<AuthSession?> get sessionChanges;

  Future<AuthSession?> restoreSession();

  Future<AuthSession?> refreshSession();

  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber);

  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  });

  Future<AuthSession> signIn(AuthProvider provider);

  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  });

  Future<void> signOut();
}

final class UnconfiguredAuthGateway implements AuthGateway {
  const UnconfiguredAuthGateway([
    this.configurationFailure = const AuthFailure(
      AuthErrorCode.configurationMissing,
      'Firebase configuration is missing',
    ),
  ]);

  @override
  final AuthFailure configurationFailure;

  @override
  bool get isConfigured => false;

  @override
  bool get supportsPhoneOtp => false;

  @override
  bool get supportsDesktopBrowserHandoff => false;

  @override
  AuthSession? get currentSession => null;

  @override
  Stream<AuthSession?> get sessionChanges => const Stream.empty();

  @override
  Future<AuthSession?> restoreSession() async => null;

  @override
  Future<AuthSession?> refreshSession() async => null;

  @override
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) => throw AuthConfigurationException();

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) =>
      throw AuthConfigurationException();

  @override
  Future<AuthSession> signIn(AuthProvider provider) =>
      throw AuthConfigurationException();

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) => throw AuthConfigurationException();

  @override
  Future<void> signOut() => throw AuthConfigurationException();
}
