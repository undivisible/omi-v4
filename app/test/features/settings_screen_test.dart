import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/meeting_notes.dart';
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

  Widget host(
    AppServices services, {
    ThemeMode mode = ThemeMode.light,
    OmiNumbersLoader? numbersLoader,
    bool disableAnimations = false,
  }) => MaterialApp(
    themeMode: mode,
    theme: ThemeData(brightness: Brightness.light),
    darkTheme: ThemeData(brightness: Brightness.dark),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: child!,
    ),
    home: SettingsScreen(
      services: services,
      previewMode: true,
      numbersLoader: numbersLoader,
    ),
  );

  /// Every colour a widget paints across the whole page. The single-background
  /// rule is that the page colour turns up exactly once — on the Scaffold —
  /// and never again underneath it.
  List<Color> paintedColors(WidgetTester tester) => [
    for (final box in tester.widgetList<ColoredBox>(find.byType(ColoredBox)))
      box.color,
    for (final box in tester.widgetList<DecoratedBox>(
      find.byType(DecoratedBox),
    ))
      if (box.decoration case final BoxDecoration decoration) ?decoration.color,
    for (final container in tester.widgetList<Container>(
      find.byType(Container),
    ))
      if (container.decoration case final BoxDecoration decoration)
        ?decoration.color,
  ];

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

  for (final (mode, page, panel, hairline) in const [
    (ThemeMode.light, Color(0xfff7f6f1), Color(0xfffffefa), Color(0x1a000000)),
    (ThemeMode.dark, Color(0xff1c1c1a), Color(0xff232321), Color(0x1affffff)),
  ]) {
    testWidgets('settings paints exactly one background in $mode', (
      tester,
    ) async {
      final services = AppServices.fromEnvironment();
      addTearDown(services.dispose);
      await tester.pumpWidget(host(services, mode: mode));
      await tester.pumpAndSettle();

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.backgroundColor, page);
      expect(
        paintedColors(tester).where((color) => color == page),
        isEmpty,
        reason: 'the page background must only come from the Scaffold',
      );
    });

    testWidgets('the settings sidebar is its own rounded panel in $mode', (
      tester,
    ) async {
      final services = AppServices.fromEnvironment();
      addTearDown(services.dispose);
      await tester.pumpWidget(host(services, mode: mode));
      await tester.pumpAndSettle();

      final sidebar = tester.widget<DecoratedBox>(
        find.byKey(const Key('settings_sidebar')),
      );
      final decoration = sidebar.decoration as BoxDecoration;
      expect(decoration.color, panel);
      expect(decoration.borderRadius, BorderRadius.circular(12));
      expect((decoration.border! as Border).top.color, hairline);

      // The sidebar is separated from the content pane, not butted up to it.
      final sidebarRect = tester.getRect(
        find.byKey(const Key('settings_sidebar')),
      );
      final headerRect = tester.getRect(find.text('Account').last);
      expect(headerRect.left, greaterThan(sidebarRect.right));
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

  group('the settings orb easter egg', () {
    Future<List<OmiNumber>> numbers() async => const [
      OmiNumber('Messages exchanged', '42'),
      OmiNumber('Meetings recorded', '3'),
    ];

    Future<void> clickOrb(WidgetTester tester, int times) async {
      for (var index = 0; index < times; index += 1) {
        await tester.tap(find.byKey(const Key('settings_orb')));
        await tester.pump();
      }
    }

    testWidgets('stays out of the way until the full click run lands', (
      tester,
    ) async {
      final services = AppServices.fromEnvironment();
      addTearDown(services.dispose);
      await tester.pumpWidget(host(services, numbersLoader: numbers));
      await tester.pumpAndSettle();

      await clickOrb(tester, 4);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('omi_numbers_card')), findsNothing);

      await clickOrb(tester, 1);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('omi_numbers_card')), findsOneWidget);
      expect(find.text('Your Omi in numbers'), findsOneWidget);
    });

    testWidgets('shows the real figures it was given, and dismisses', (
      tester,
    ) async {
      final services = AppServices.fromEnvironment();
      addTearDown(services.dispose);
      await tester.pumpWidget(host(services, numbersLoader: numbers));
      await tester.pumpAndSettle();

      await clickOrb(tester, 5);
      await tester.pumpAndSettle();

      expect(find.text('Messages exchanged'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('Meetings recorded'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      await tester.tap(find.byKey(const Key('omi_numbers_dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('omi_numbers_card')), findsNothing);
      // Nothing about settings itself was disturbed.
      expect(find.byKey(const Key('settings_section_account')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('needs the clicks in quick succession', (tester) async {
      final services = AppServices.fromEnvironment();
      addTearDown(services.dispose);
      await tester.pumpWidget(host(services, numbersLoader: numbers));
      await tester.pumpAndSettle();

      await clickOrb(tester, 4);
      // The streak is measured on the wall clock, so let it lapse for real.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 900)),
      );
      await clickOrb(tester, 1);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('omi_numbers_card')), findsNothing);
    });

    testWidgets('bursts on reveal, and stays still under reduced motion', (
      tester,
    ) async {
      final services = AppServices.fromEnvironment();
      addTearDown(services.dispose);
      await tester.pumpWidget(host(services, numbersLoader: numbers));
      await tester.pumpAndSettle();

      await clickOrb(tester, 5);
      await tester.pump();
      expect(find.byKey(const Key('settings_orb_burst')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings_orb_burst')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        host(services, numbersLoader: numbers, disableAnimations: true),
      );
      await tester.pumpAndSettle();

      await clickOrb(tester, 5);
      expect(find.byKey(const Key('settings_orb_burst')), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings_orb_burst')), findsNothing);
      expect(find.byKey(const Key('omi_numbers_card')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('counts only what the stores actually hold', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final services = makeServices();
      final now = DateTime.now().toUtc();
      services.meetingNotes = VolatileMeetingNotesStore()
        ..notes.add(
          MeetingNote(
            id: 'meeting-1',
            title: 'Design sync',
            summary: '',
            startedAt: now.subtract(const Duration(days: 4)),
            endedAt: now.subtract(const Duration(days: 4, minutes: -25)),
            participants: const [],
            keyPoints: const [],
            decisions: const [],
            actions: const [],
            markdown: '',
            metadataJson: '',
          ),
        );

      final values = await loadOmiNumbers(services);
      final labels = [for (final value in values) value.label];

      expect(labels, contains('Meetings recorded'));
      expect(
        values.firstWhere((value) => value.label == 'Meetings recorded').value,
        '1',
      );
      expect(
        values
            .firstWhere((value) => value.label == 'Minutes transcribed')
            .value,
        '25',
      );
      expect(
        values.firstWhere((value) => value.label == 'Days with Omi').value,
        '4',
      );
      // Nothing was exchanged, so that line is left out rather than shown
      // as a zero.
      expect(labels, isNot(contains('Messages exchanged')));
    });
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
