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

  AuthSession? get currentSession;

  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber);

  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  });

  Future<AuthSession> signIn(AuthProvider provider);

  Future<void> signOut();
}

final class UnconfiguredAuthGateway implements AuthGateway {
  const UnconfiguredAuthGateway();

  @override
  bool get isConfigured => false;

  @override
  AuthSession? get currentSession => null;

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
  Future<void> signOut() => throw AuthConfigurationException();
}
