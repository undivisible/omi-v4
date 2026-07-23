import 'package:flutter/foundation.dart';
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

  test('maps every known firebase error code and defaults to unknown', () {
    const expected = {
      'invalid-phone-number': AuthErrorCode.invalidPhoneNumber,
      'invalid-verification-code': AuthErrorCode.invalidOtp,
      'session-expired': AuthErrorCode.otpExpired,
      'code-expired': AuthErrorCode.otpExpired,
      'too-many-requests': AuthErrorCode.rateLimited,
      'quota-exceeded': AuthErrorCode.rateLimited,
      'canceled': AuthErrorCode.cancelled,
      'network-request-failed': AuthErrorCode.network,
      'unimplemented': AuthErrorCode.unsupportedPlatform,
      'something-new': AuthErrorCode.unknown,
    };

    expected.forEach((code, errorCode) {
      expect(firebaseFailureForCode(code).code, errorCode, reason: code);
    });
    expect(
      firebaseFailureForCode('unknown-code').message,
      'Authentication failed',
    );
    expect(
      firebaseFailureForCode('unknown-code', 'server said no').message,
      'server said no',
    );
  });

  test('each identifier is validated independently', () {
    FirebaseClientOptions parse({
      String apiKeyValue = apiKey,
      String appIdValue = appId,
      String messagingSenderId = '123456789',
      String projectId = 'omi-project',
      String authDomain = 'omi-project.firebaseapp.com',
      FirebaseClientPlatform platform = FirebaseClientPlatform.web,
    }) => FirebaseClientOptions.parse(
      platform: platform,
      apiKey: apiKeyValue,
      appId: appIdValue,
      messagingSenderId: messagingSenderId,
      projectId: projectId,
      authDomain: authDomain,
    );

    expect(
      () => parse(apiKeyValue: 'AIzaShort'),
      throwsA(
        isA<FirebaseOptionsException>().having(
          (error) => error.message,
          'message',
          'FIREBASE_API_KEY is invalid',
        ),
      ),
    );
    expect(
      () => parse(appIdValue: '1:123456789:ios:abcdef123456'),
      throwsA(
        isA<FirebaseOptionsException>().having(
          (error) => error.message,
          'message',
          'FIREBASE_APP_ID is invalid',
        ),
      ),
    );
    expect(
      () => parse(appIdValue: 'not-an-app-id'),
      throwsA(isA<FirebaseOptionsException>()),
    );
    expect(
      () => parse(messagingSenderId: '12ab'),
      throwsA(
        isA<FirebaseOptionsException>().having(
          (error) => error.message,
          'message',
          'FIREBASE_MESSAGING_SENDER_ID is invalid',
        ),
      ),
    );
    expect(
      () => parse(projectId: 'omi'),
      throwsA(
        isA<FirebaseOptionsException>().having(
          (error) => error.message,
          'message',
          'FIREBASE_PROJECT_ID is invalid',
        ),
      ),
    );
    expect(
      () => parse(projectId: 'Omi-Project'),
      throwsA(isA<FirebaseOptionsException>()),
    );
    expect(
      () => parse(authDomain: 'not a host'),
      throwsA(
        isA<FirebaseOptionsException>().having(
          (error) => error.message,
          'message',
          'FIREBASE_AUTH_DOMAIN must be a valid web host',
        ),
      ),
    );
  });

  test('a bad auth domain is rejected even off the web', () {
    expect(
      () => FirebaseClientOptions.parse(
        platform: FirebaseClientPlatform.macos,
        apiKey: apiKey,
        appId: '1:123456789:ios:abcdef123456',
        messagingSenderId: '123456789',
        projectId: 'omi-project',
        authDomain: 'localhost',
      ),
      throwsA(
        isA<FirebaseOptionsException>().having(
          (error) => error.message,
          'message',
          'FIREBASE_AUTH_DOMAIN is invalid',
        ),
      ),
    );
  });

  test('auth domains are normalised and optional off the web', () {
    final options = FirebaseClientOptions.parse(
      platform: FirebaseClientPlatform.windows,
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: '123456789',
      projectId: 'omi-project',
      authDomain: '  OMI-Project.FirebaseApp.com ',
    );
    final bare = FirebaseClientOptions.parse(
      platform: FirebaseClientPlatform.android,
      apiKey: apiKey,
      appId: '1:123456789:android:abcdef123456',
      messagingSenderId: '123456789',
      projectId: 'omi-project',
    );

    expect(options.authDomain, 'omi-project.firebaseapp.com');
    expect(options.platform.supportsPhoneOtp, isFalse);
    expect(bare.authDomain, isNull);
    expect(bare.firebaseOptions.authDomain, isNull);
    expect(bare.platform.supportsPhoneOtp, isTrue);
  });

  test('an unconfigured environment degrades instead of crashing', () async {
    expect(
      FirebaseClientOptions.fromEnvironment,
      throwsA(isA<FirebaseOptionsException>()),
    );

    final gateway = await initializeFirebaseAuth();

    expect(gateway.isConfigured, isFalse);
    expect(
      gateway.configurationFailure?.code,
      AuthErrorCode.configurationMissing,
    );
    expect(gateway.currentSession, isNull);
    expect(gateway.supportsDesktopBrowserHandoff, isFalse);
  });

  test('unsupported desktop platforms are named as such', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    expect(
      FirebaseClientOptions.fromEnvironment,
      throwsA(
        isA<FirebaseOptionsException>().having(
          (error) => error.message,
          'message',
          'Firebase authentication is not supported on this platform',
        ),
      ),
    );
  });
}
