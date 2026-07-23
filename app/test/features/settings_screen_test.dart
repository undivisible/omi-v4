import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/setup_account_screens.dart';
import 'package:omi/native/native_hub.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppServices makeServices({AuthController? auth}) {
    final services = AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: auth ?? AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    addTearDown(services.dispose);
    return services;
  }

  Widget host(AppServices services, {ThemeMode mode = ThemeMode.light}) =>
      MaterialApp(
        themeMode: mode,
        theme: ThemeData(brightness: Brightness.light),
        darkTheme: ThemeData(brightness: Brightness.dark),
        home: SettingsScreen(services: services, previewMode: true),
      );

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('settings renders without Material errors in $mode', (
      tester,
    ) async {
      final services = AppServices.fromEnvironment();
      addTearDown(services.dispose);
      await tester.pumpWidget(host(services, mode: mode));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(
        find.text('Account access is disabled in the interface preview.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('sections navigate between panes', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final services = AppServices.fromEnvironment();
    addTearDown(services.dispose);
    await tester.pumpWidget(host(services));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings_section_account')), findsOneWidget);
    expect(find.byKey(const Key('settings_section_calendar')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings_section_plan')));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to manage your plan.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings_section_providers')));
    await tester.pumpAndSettle();
    expect(
      find.text('Configure BYOK securely from a native Omi app.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('settings_section_permissions')));
    await tester.pumpAndSettle();
    expect(find.text('Allow screen understanding'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings_section_advanced')));
    await tester.pumpAndSettle();
    expect(find.text('Agent control unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('settings route pushed without a scaffold still renders', (
    tester,
  ) async {
    final services = AppServices.fromEnvironment();
    addTearDown(services.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                fullscreenDialog: true,
                builder: (context) =>
                    SettingsScreen(services: services, previewMode: true),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const Key('settings_close')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('settings_close')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('delete account requires confirmation', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final services = AppServices.fromEnvironment();
    addTearDown(services.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DeleteAccountTile(services: services)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete_account')));
    await tester.pumpAndSettle();
    expect(find.text('Delete account?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete_account_cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Delete account?'), findsNothing);

    await tester.tap(find.byKey(const Key('delete_account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete_account_confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Delete account?'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('signed-in account section shows log out and delete account', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final auth = AuthController(_SignedInGateway());
    await auth.restoreSession();
    final services = makeServices(auth: auth);
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(services: services)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sign_out')), findsOneWidget);
    expect(find.text('Log out'), findsWidgets);
    expect(find.byKey(const Key('delete_account')), findsOneWidget);
    expect(find.byKey(const Key('delete_local_data')), findsNothing);
  });

  testWidgets('signed-out account section shows a single delete data action', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final services = makeServices();
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(services: services)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sign_out')), findsNothing);
    expect(find.byKey(const Key('delete_account')), findsNothing);
    expect(find.byKey(const Key('delete_local_data')), findsOneWidget);
  });

  testWidgets('delete data confirms, wipes local stores, and signals a wipe', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_complete_v1_local': true,
      'hub_starter_tasks_v1': ['Pick omi back up'],
    });
    final services = makeServices();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DeleteLocalDataTile(services: services)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete_local_data')));
    await tester.pumpAndSettle();
    expect(find.text('Delete data?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete_local_data_cancel')));
    await tester.pumpAndSettle();
    final untouched = await SharedPreferences.getInstance();
    expect(untouched.getBool('onboarding_complete_v1_local'), isTrue);

    await tester.tap(find.byKey(const Key('delete_local_data')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete_local_data_confirm')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('onboarding_complete_v1_local'), isNull);
    expect(prefs.getStringList('hub_starter_tasks_v1'), isNull);
    expect(services.dataWipes.value, 1);
    expect(tester.takeException(), isNull);
  });
}

final class _SignedInGateway implements AuthGateway {
  final _session = AuthSession(
    uid: 'user-a',
    idToken: 'token',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    displayName: 'Ada',
  );

  @override
  bool get isConfigured => true;

  @override
  AuthFailure? get configurationFailure => null;

  @override
  bool get supportsPhoneOtp => false;

  @override
  bool get supportsDesktopBrowserHandoff => false;

  @override
  AuthSession? get currentSession => _session;

  @override
  Stream<AuthSession?> get sessionChanges => const Stream.empty();

  @override
  Future<AuthSession?> restoreSession() async => _session;

  @override
  Future<AuthSession?> refreshSession() async => _session;

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
