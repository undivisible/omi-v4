import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/chat_screen.dart';
import 'package:omi/features/omi_shell.dart';
import 'package:omi/features/setup_account_screens.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/onboarding/hub_checklist.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppServices makeServices() => AppServices.forTesting(
    nativeHub: const UnavailableNativeHub('test'),
    deviceRelay: DeviceRelayService(
      role: DeviceRelayRole.desktopObserver,
      adapter: const UnavailableDeviceRelayAdapter(),
    ),
    auth: AuthController(const UnconfiguredAuthGateway()),
    memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
  );

  Widget host(
    AppServices services, {
    VoidCallback? onOpenProviderSettings,
    EntitlementProbe? entitlementProbe,
  }) => MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        services: services,
        previewMode: true,
        checklistStore: VolatileHubChecklistStore(),
        onOpenProviderSettings: onOpenProviderSettings,
        entitlementProbe: entitlementProbe,
      ),
    ),
  );

  testWidgets(
    'the BYOK hint shows on a free plan and opens provider settings',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final services = makeServices();
      addTearDown(services.dispose);
      var opened = 0;
      await tester.pumpWidget(
        host(
          services,
          onOpenProviderSettings: () => opened += 1,
          entitlementProbe: () async =>
              const BillingEntitlement(plan: OmiPlan.byok, active: true),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('hub_byok_hint')), findsOneWidget);
      await tester.tap(find.byKey(const Key('hub_byok_hint_open')));
      await tester.pump();
      expect(opened, 1);
    },
  );

  testWidgets('the BYOK hint stays hidden on an active paid plan', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final services = makeServices();
    addTearDown(services.dispose);
    await tester.pumpWidget(
      host(
        services,
        entitlementProbe: () async =>
            const BillingEntitlement(plan: OmiPlan.pro, active: true),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('hub_byok_hint')), findsNothing);
    expect(
      find.text('By the way, if you bring your own keys, Omi becomes free.'),
      findsNothing,
    );
  });

  testWidgets('a lapsed paid plan is free again, so the hint comes back', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final services = makeServices();
    addTearDown(services.dispose);
    await tester.pumpWidget(
      host(
        services,
        entitlementProbe: () async =>
            const BillingEntitlement(plan: OmiPlan.pro, active: false),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('hub_byok_hint')), findsOneWidget);
  });

  testWidgets('dismissing the BYOK hint persists across a rebuild', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final services = makeServices();
    addTearDown(services.dispose);
    await tester.pumpWidget(host(services));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('hub_byok_hint')), findsOneWidget);

    await tester.tap(find.byKey(const Key('hub_byok_hint_dismiss')));
    await tester.pump();
    expect(find.byKey(const Key('hub_byok_hint')), findsNothing);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(ChatScreenState.byokHintDismissedKey), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(host(services));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('hub_byok_hint')), findsNothing);
  });

  testWidgets(
    'tapping the hub BYOK hint asks the Runner for the provider-keys section',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      SharedPreferences.setMockInitialValues({});
      final messenger = tester.binding.defaultBinaryMessenger;
      final chromeCalls = <MethodCall>[];
      const windowChrome = MethodChannel('omi/window_chrome');
      const menuBar = MethodChannel('omi/menu_bar');
      messenger.setMockMethodCallHandler(windowChrome, (call) async {
        chromeCalls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(menuBar, (call) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChrome, null);
        messenger.setMockMethodCallHandler(menuBar, null);
      });

      final services = makeServices();
      addTearDown(services.dispose);
      await tester.pumpWidget(MaterialApp(home: OmiShell(services: services)));
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.byKey(const Key('hub_byok_hint_open')));
      await tester.pump();

      final open = chromeCalls.where((call) => call.method == 'openSettings');
      expect(open, hasLength(1));
      expect(open.single.arguments, SettingsSection.providers.name);
      expect(find.byType(SettingsScreen), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'the in-window fallback opens settings on the asked-for section',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final services = makeServices();
      addTearDown(services.dispose);
      await tester.pumpWidget(
        MaterialApp(home: OmiShell(services: services, previewMode: true)),
      );
      await tester.pump(const Duration(seconds: 2));

      final state = tester.state(find.byType(OmiShell)) as dynamic;
      // ignore: avoid_dynamic_calls
      state.debugOpenSettingsForTest(section: SettingsSection.providers);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(SettingsScreen), findsOneWidget);
      final screen = tester.widget<SettingsScreen>(find.byType(SettingsScreen));
      expect(screen.initialSection, SettingsSection.providers);
      expect(find.text('AI Providers'), findsWidgets);
    },
  );
}
