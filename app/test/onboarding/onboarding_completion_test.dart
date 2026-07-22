import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/main.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/onboarding/onboarding_completion.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('preferences persist completion per Firebase UID', () async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferencesOnboardingCompletionStore();

    await store.complete('user-a');

    expect(
      await PreferencesOnboardingCompletionStore().isComplete('user-a'),
      isTrue,
    );
    expect(
      await PreferencesOnboardingCompletionStore().isComplete('user-b'),
      isFalse,
    );
  });

  testWidgets('same completed UID returns directly to the shell', (
    tester,
  ) async {
    final store = VolatileOnboardingCompletionStore();
    await store.complete('user-a');
    final first = await _authorizedServices('user-a');

    await tester.pumpWidget(
      OmiApp(services: first, onboardingCompletionStore: store),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat_input')), findsOneWidget);
    expect(find.text('Let’s build your second brain.'), findsNothing);
  });

  testWidgets('account switching cannot reuse another UID completion', (
    tester,
  ) async {
    final store = VolatileOnboardingCompletionStore();
    await store.complete('user-a');
    final services = await _authorizedServices('user-a');

    await tester.pumpWidget(
      OmiApp(services: services, onboardingCompletionStore: store),
    );
    await tester.pumpAndSettle();
    final gateway = _gateways[services]!;
    gateway.currentSession = _session('user-b');
    await services.auth.setConsent(true);
    await services.auth.grantProcessingConsent();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('Hi, I’m Omi.'), findsOneWidget);
    expect(await store.isComplete('user-b'), isFalse);
  });

  testWidgets('consent revocation immediately returns to onboarding', (
    tester,
  ) async {
    final store = VolatileOnboardingCompletionStore();
    await store.complete('user-a');
    final services = await _authorizedServices('user-a');

    await tester.pumpWidget(
      OmiApp(services: services, onboardingCompletionStore: store),
    );
    await tester.pumpAndSettle();
    await services.auth.revokeProcessingConsent();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('Hi, I’m Omi.'), findsOneWidget);
    expect(find.byKey(const Key('chat_input')), findsNothing);
  });
}

final _gateways = Expando<_Gateway>();

Future<AppServices> _authorizedServices(String uid) async {
  final gateway = _Gateway(_session(uid));
  final auth = AuthController(gateway, consentStore: VolatileConsentStore());
  await auth.setConsent(true);
  await auth.grantProcessingConsent();
  final services = AppServices.forTesting(
    nativeHub: const UnavailableNativeHub('test'),
    deviceRelay: DeviceRelayService(
      role: DeviceRelayRole.desktopObserver,
      adapter: const UnavailableDeviceRelayAdapter(),
    ),
    auth: auth,
    memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
  );
  _gateways[services] = gateway;
  return services;
}

AuthSession _session(String uid) =>
    AuthSession(uid: uid, idToken: 'token-$uid', expiresAt: DateTime.utc(2030));

final class _Gateway implements AuthGateway {
  _Gateway(this.currentSession);

  @override
  AuthSession? currentSession;

  @override
  AuthFailure? get configurationFailure => null;

  @override
  bool get isConfigured => true;

  @override
  Stream<AuthSession?> get sessionChanges => const Stream.empty();

  @override
  bool get supportsDesktopBrowserHandoff => false;

  @override
  bool get supportsPhoneOtp => true;

  @override
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) async => currentSession!;

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) async =>
      const PhoneOtpChallenge(verificationId: 'test');

  @override
  Future<AuthSession?> refreshSession() async => currentSession;

  @override
  Future<AuthSession?> restoreSession() async => currentSession;

  @override
  Future<AuthSession> signIn(AuthProvider provider) async => currentSession!;

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) async => currentSession!;

  @override
  Future<void> signOut() async => currentSession = null;
}
