import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/web_portal_screen.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  testWidgets('web portal records processing consent after Firebase sign-in', (
    tester,
  ) async {
    final gateway = _Gateway();
    final auth = AuthController(gateway, consentStore: VolatileConsentStore());
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: _FakeHub(),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await tester.pumpWidget(
      MaterialApp(home: WebPortalScreen(services: services)),
    );

    expect(find.text('Sign in to Omi'), findsOneWidget);
    await auth.setConsent(true);
    await auth.signIn(AuthProvider.google);
    await tester.pumpAndSettle();

    expect(auth.snapshot.hasProcessingAuthority, isTrue);
    expect(services.productionReady, isTrue);
    expect(find.text('Sign in to Omi'), findsNothing);
  });
}

final class _Gateway implements AuthGateway {
  final _session = AuthSession(
    uid: 'portal-user',
    idToken: 'portal-token',
    expiresAt: DateTime.utc(2030),
    email: 'user@example.test',
  );

  @override
  AuthFailure? get configurationFailure => null;

  @override
  bool get isConfigured => true;

  @override
  Stream<AuthSession?> get sessionChanges => const Stream.empty();

  @override
  bool get supportsPhoneOtp => true;

  @override
  bool get supportsDesktopBrowserHandoff => false;

  @override
  AuthSession? get currentSession => _session;

  @override
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) async => _session;

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) async =>
      const PhoneOtpChallenge(verificationId: 'challenge');

  @override
  Future<AuthSession?> refreshSession({bool forceRefresh = false}) async =>
      _session;

  @override
  Future<AuthSession?> restoreSession() async => null;

  @override
  Future<AuthSession> signIn(AuthProvider provider) async => _session;

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) async => _session;

  @override
  Future<void> signOut() async {}
}

final class _FakeHub implements NativeHub {
  @override
  Object? noSuchMethod(Invocation invocation) => null;
}
