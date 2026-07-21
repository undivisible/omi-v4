import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/features/desktop_auth_screen.dart';
import 'package:omi/features/onboarding_screen.dart';

void main() {
  final session = AuthSession(
    uid: 'firebase-uid',
    idToken: 'firebase-token',
    expiresAt: DateTime.utc(2030),
    phoneNumber: '+15555550123',
  );

  testWidgets(
    'processing consent and Firebase phone disclosure stay separate',
    (tester) async {
      final gateway = _Gateway(session);
      final store = VolatileConsentStore();
      final auth = AuthController(gateway, consentStore: store);

      await tester.pumpWidget(_controls(auth));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('request_phone_otp')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const Key('firebase_auth_acknowledgement')));
      await tester.pumpAndSettle();
      expect(auth.snapshot.consentGranted, isTrue);
      expect(await store.currentReceipt(), isNull);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('request_phone_otp')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const Key('firebase_phone_disclosure')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('request_phone_otp')))
            .onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(const Key('sign_in_google')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('grant_processing_consent')));
      await tester.pumpAndSettle();
      expect(auth.snapshot.hasProcessingAuthority, isTrue);
      expect((await store.currentReceipt())?.subjectUid, 'firebase-uid');

      await tester.tap(find.byKey(const Key('revoke_processing_consent')));
      await tester.pumpAndSettle();
      expect(auth.snapshot.consentGranted, isFalse);
      expect(await store.currentReceipt(), isNull);
      expect(gateway.didSignOut, isTrue);
    },
  );

  testWidgets('sign out does not silently revoke processing consent', (
    tester,
  ) async {
    final gateway = _Gateway(session, currentSession: session);
    final store = VolatileConsentStore();
    final auth = AuthController(gateway, consentStore: store);
    await auth.setConsent(true);
    await auth.grantProcessingConsent();

    await tester.pumpWidget(_controls(auth));
    await tester.tap(find.byKey(const Key('sign_out_firebase')));
    await tester.pumpAndSettle();

    expect(auth.snapshot.phase, AuthPhase.signedOut);
    expect((await store.currentReceipt())?.subjectUid, 'firebase-uid');
    expect(gateway.didSignOut, isTrue);
  });

  testWidgets('desktop completion recovers when session refresh fails', (
    tester,
  ) async {
    final gateway = _Gateway(
      session,
      currentSession: session,
      failRefresh: true,
    );
    final auth = AuthController(gateway);
    await auth.restoreSession();
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopAuthScreen.forTesting(auth: auth, sessionId: 'session-id'),
      ),
    );

    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm this desktop'));
    await tester.pumpAndSettle();

    expect(find.text('Session refresh failed. Retry.'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Confirm this desktop'),
          )
          .onPressed,
      isNotNull,
    );
  });
}

Widget _controls(AuthController auth) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: ListenableBuilder(
      listenable: auth,
      builder: (context, _) => ListView(
        children: [
          ProcessingConsentGate(auth: auth),
          AuthenticationGate(auth: auth, configurationMessage: 'configured'),
        ],
      ),
    ),
  ),
);

final class _Gateway implements AuthGateway {
  _Gateway(this.session, {this.currentSession, this.failRefresh = false});

  final AuthSession session;
  @override
  AuthSession? currentSession;
  bool didSignOut = false;
  final bool failRefresh;

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
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) async => session;

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) async =>
      const PhoneOtpChallenge(verificationId: 'challenge');

  @override
  Future<AuthSession?> refreshSession() async {
    if (failRefresh) {
      throw const AuthOperationException(
        AuthFailure(AuthErrorCode.network, 'Session refresh failed. Retry.'),
      );
    }
    return currentSession;
  }

  @override
  Future<AuthSession?> restoreSession() async => currentSession;

  @override
  Future<AuthSession> signIn(AuthProvider provider) async =>
      currentSession = session;

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) async => currentSession = session;

  @override
  Future<void> signOut() async {
    didSignOut = true;
    currentSession = null;
  }
}
