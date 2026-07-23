import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/omi_shell.dart';
import 'package:omi/features/setup_account_screens.dart';
import 'package:omi/main.dart';
import 'package:omi/native/native_hub.dart';

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

  testWidgets(
    'the menu-bar/⌘, settings path asks the Runner to open the native '
    'settings window over omi/window_chrome instead of pushing a route',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final messenger = tester.binding.defaultBinaryMessenger;
      final chromeCalls = <String>[];
      const windowChrome = MethodChannel('omi/window_chrome');
      const menuBar = MethodChannel('omi/menu_bar');
      messenger.setMockMethodCallHandler(windowChrome, (call) async {
        chromeCalls.add(call.method);
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

      // The Runner's menu bar (and its ⌘, item) reports "openSettings" back
      // over omi/menu_bar; the shell must forward it to the native settings
      // window rather than opening an in-window route.
      await messenger.handlePlatformMessage(
        'omi/menu_bar',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('openSettings'),
        ),
        (_) {},
      );
      await tester.pump();

      expect(chromeCalls, contains('openSettings'));
      expect(find.byType(SettingsScreen), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'a silent regression is impossible: on macOS the in-window fallback '
    'reports the failed channel call instead of quietly opening a route',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final messenger = tester.binding.defaultBinaryMessenger;
      const windowChrome = MethodChannel('omi/window_chrome');
      const menuBar = MethodChannel('omi/menu_bar');
      // A Runner that answers the channel but cannot open the window — the
      // shape of every native settings regression.
      messenger.setMockMethodCallHandler(windowChrome, (call) async {
        if (call.method != 'openSettings') return null;
        throw PlatformException(code: 'settings_window_unavailable');
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

      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      final state = tester.state(find.byType(OmiShell)) as dynamic;
      // ignore: avoid_dynamic_calls
      state.debugOpenSettingsForTest();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      FlutterError.onError = previous;

      expect(reported, isNotEmpty);
      expect(reported.single.exception, isA<PlatformException>());
      expect(reported.single.context.toString(), contains('omi/window_chrome'));
      // Loud, but still not stranded: the route is the release behaviour.
      expect(find.byType(SettingsScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'without the native channel the settings fall back to the in-window '
    'route',
    (tester) async {
      final services = makeServices();
      addTearDown(services.dispose);
      await tester.pumpWidget(
        MaterialApp(home: OmiShell(services: services, previewMode: true)),
      );
      await tester.pump(const Duration(seconds: 2));

      final state = tester.state(find.byType(OmiShell)) as dynamic;
      // ignore: avoid_dynamic_calls
      state.debugOpenSettingsForTest();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(SettingsScreen), findsOneWidget);
    },
  );

  testWidgets(
    'the settings window opens on the section the Runner was asked for, and '
    'moves when a later request arrives',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      final asked = <String>[];
      messenger.setMockMethodCallHandler(settingsRouteChannel, (call) async {
        asked.add(call.method);
        return call.method == 'pendingSection'
            ? SettingsSection.providers.name
            : null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(settingsRouteChannel, null),
      );

      final services = AppServices.fromEnvironment();
      addTearDown(services.dispose);
      await tester.pumpWidget(SettingsWindowApp(services: services));
      await tester.pumpAndSettle();

      expect(asked, contains('pendingSection'));
      final screen = tester.widget<SettingsScreen>(find.byType(SettingsScreen));
      expect(screen.initialSection, SettingsSection.providers);
      expect(find.text('AI Providers'), findsWidgets);

      // The window is already up: the Runner pushes the next anchor at it.
      await messenger.handlePlatformMessage(
        'omi/settings_route',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('showSection', SettingsSection.advanced.name),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();

      expect(find.text('Advanced'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
