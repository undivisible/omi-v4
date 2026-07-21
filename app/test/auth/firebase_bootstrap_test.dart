import 'package:flutter_test/flutter_test.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/auth/firebase_bootstrap.dart';

void main() {
  const apiKey = 'AIza12345678901234567890123456789012345';
  const appId = '1:123456789:web:abcdef123456';

  test('validates platform-aware Firebase client options', () {
    final web = FirebaseClientOptions.parse(
      platform: FirebaseClientPlatform.web,
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: '123456789',
      projectId: 'omi-project',
      authDomain: 'omi-project.firebaseapp.com',
    );
    final macos = FirebaseClientOptions.parse(
      platform: FirebaseClientPlatform.macos,
      apiKey: apiKey,
      appId: '1:123456789:ios:abcdef123456',
      messagingSenderId: '123456789',
      projectId: 'omi-project',
    );

    expect(web.platform.supportsPhoneOtp, isTrue);
    expect(macos.platform.supportsPhoneOtp, isFalse);
    expect(web.firebaseOptions.authDomain, 'omi-project.firebaseapp.com');
  });

  test('web configuration requires a valid auth domain', () {
    expect(
      () => FirebaseClientOptions.parse(
        platform: FirebaseClientPlatform.web,
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: '123456789',
        projectId: 'omi-project',
      ),
      throwsA(isA<FirebaseOptionsException>()),
    );
    expect(
      () => FirebaseClientOptions.parse(
        platform: FirebaseClientPlatform.web,
        apiKey: 'invalid',
        appId: appId,
        messagingSenderId: '123456789',
        projectId: 'omi-project',
        authDomain: 'omi-project.firebaseapp.com',
      ),
      throwsA(isA<FirebaseOptionsException>()),
    );
    expect(
      () => FirebaseClientOptions.parse(
        platform: FirebaseClientPlatform.android,
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: '123456789',
        projectId: 'omi-project',
      ),
      throwsA(isA<FirebaseOptionsException>()),
    );
  });

  test('maps provider cancellation and unsupported failures', () {
    expect(
      firebaseFailureForCode('popup-closed-by-user').code,
      AuthErrorCode.cancelled,
    );
    expect(
      firebaseFailureForCode('web-context-cancelled').code,
      AuthErrorCode.cancelled,
    );
    expect(
      firebaseFailureForCode(
        'operation-not-supported-in-this-environment',
      ).code,
      AuthErrorCode.unsupportedPlatform,
    );
  });
}
