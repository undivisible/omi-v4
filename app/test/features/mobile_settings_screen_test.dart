import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/mobile_settings_screen.dart';
import 'package:omi/features/setup_account_screens.dart';
import 'package:omi/native/native_hub.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppServices makeServices({AuthController? auth}) {
    final services = AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: auth ?? AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    addTearDown(services.dispose);
    return services;
  }

  Future<void> pumpPhone(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: child));
    await tester.pumpAndSettle();
  }

  testWidgets('the phone lists every account and product section', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final services = makeServices();
    await pumpPhone(
      tester,
      MobileSettingsScreen(services: services, previewMode: true),
    );

    expect(find.byKey(const Key('mobile_settings_screen')), findsOneWidget);
    for (final section in mobileSettingsSections) {
      expect(
        find.byKey(Key('mobile_settings_section_${section.name}')),
        findsOneWidget,
        reason: '${section.name} is missing from the phone',
      );
    }
    // Nothing on a phone can grant screen recording, macOS Accessibility, or
    // system audio capture, and Rewind never runs there.
    for (final section in const [
      SettingsSection.permissions,
      SettingsSection.calendar,
      SettingsSection.rewind,
    ]) {
      expect(
        find.byKey(Key('mobile_settings_section_${section.name}')),
        findsNothing,
        reason: '${section.name} does not belong on a phone',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('every section opens without overflowing a phone', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final services = makeServices();
    for (final section in mobileSettingsSections) {
      await pumpPhone(
        tester,
        MobileSettingsSectionScreen(
          section: section,
          services: services,
          previewMode: true,
        ),
      );
      expect(
        find.byKey(Key('mobile_settings_${section.name}_screen')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: section.name);
    }
  });

  testWidgets('signing in by code works from the phone', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _Gateway();
    final services = makeServices(auth: AuthController(gateway));
    await services.auth.restoreSession();
    await pumpPhone(
      tester,
      MobileSettingsScreen(services: services, previewMode: false),
    );

    await tester.tap(
      find.byKey(
        Key('mobile_settings_section_${SettingsSection.account.name}'),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const Key('settings_sign_in_code'));
    expect(field, findsOneWidget);
    await tester.enterText(field, 'ab12cd3');
    await tester.tap(find.byKey(const Key('settings_sign_in')));
    await tester.pumpAndSettle();

    expect(gateway.redeemedCode, 'ab12cd3');
    // The session lands on the same page the code was typed on, so the rows
    // that need an account have to follow it without a second navigation.
    expect(find.byKey(const Key('settings_sign_in_code')), findsNothing);
    expect(find.byKey(const Key('sign_out')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _Gateway implements AuthGateway {
  String? redeemedCode;

  @override
  bool get isConfigured => true;

  @override
  AuthFailure? get configurationFailure => null;

  @override
  bool get supportsPhoneOtp => false;

  @override
  bool get supportsDesktopBrowserHandoff => false;

  @override
  bool get supportsChannelCode => true;

  @override
  Future<AuthSession> signInWithChannelCode(String code) async {
    redeemedCode = code;
    return AuthSession(
      uid: 'user-a',
      idToken: 'token',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      displayName: 'Signed in',
    );
  }

  @override
  AuthSession? get currentSession => null;

  @override
  Stream<AuthSession?> get sessionChanges => const Stream.empty();

  @override
  Future<AuthSession?> restoreSession() async => null;

  @override
  Future<AuthSession?> refreshSession({bool forceRefresh = false}) async =>
      null;

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) => throw UnimplementedError();

  @override
  Future<AuthSession> signIn(AuthProvider provider) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) => throw UnimplementedError();

  @override
  Future<void> signOut() async {}
}
