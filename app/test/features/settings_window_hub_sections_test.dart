import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/hub_window_route.dart';
import 'package:omi/features/omi_shell.dart';
import 'package:omi/features/setup_account_screens.dart';
import 'package:omi/native/native_hub.dart';

/// A hub that fails the test if the settings engine ever tries to bind it.
///
/// rinf keeps one global Dart isolate handle for the Rust hub and replaces it
/// on every `initializeRust`, and starting the Rust logic again tears the
/// running runtime down. A second engine binding it does not gain a hub, it
/// takes the hub window's away.
final class _ForbiddenNativeHub implements NativeHub {
  var initialized = false;

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => const Stream.empty();

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppServices makeServices({
    required bool settingsWindow,
    NativeHub? nativeHub,
  }) => AppServices.forTesting(
    nativeHub: nativeHub ?? const UnavailableNativeHub('test'),
    deviceRelay: DeviceRelayService(
      role: DeviceRelayRole.desktopObserver,
      adapter: const UnavailableDeviceRelayAdapter(),
    ),
    auth: AuthController(const UnconfiguredAuthGateway()),
    memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    settingsWindow: settingsWindow,
  );

  test('the settings window never binds the Rust hub, because the process only '
      'has one binding and the hub window is holding it', () async {
    final hub = _ForbiddenNativeHub();
    final services = makeServices(settingsWindow: true, nativeHub: hub);
    addTearDown(services.dispose);

    expect(services.isSettingsWindow, isTrue);
    expect(await services.ensureNativeHubReady(), isFalse);
    expect(hub.initialized, isFalse);
  });

  test('the hub window still brings its own hub up on demand', () async {
    final hub = _ForbiddenNativeHub();
    final services = makeServices(settingsWindow: false, nativeHub: hub);
    addTearDown(services.dispose);

    expect(services.isSettingsWindow, isFalse);
    expect(await services.ensureNativeHubReady(), isTrue);
    expect(hub.initialized, isTrue);
  });

  testWidgets(
    'Settings → Rewind in the settings window offers the control instead of '
    'a dead pane, and the button reaches the hub window',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final messenger = tester.binding.defaultBinaryMessenger;
      final asked = <MethodCall>[];
      messenger.setMockMethodCallHandler(settingsRouteChannel, (call) async {
        asked.add(call);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(settingsRouteChannel, null),
      );

      final services = makeServices(settingsWindow: true);
      addTearDown(services.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            services: services,
            initialSection: SettingsSection.rewind,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('The Rewind engine did not answer.'), findsNothing);
      expect(find.text('Rewind runs in the Omi window'), findsOneWidget);

      await tester.tap(find.byKey(const Key('hub_window_section_rewind')));
      await tester.pump();
      await tester.pump();

      expect(asked.map((call) => call.method), contains('openInHub'));
      expect(
        asked.firstWhere((call) => call.method == 'openInHub').arguments,
        SettingsSection.rewind.name,
      );
      expect(
        find.byKey(const Key('hub_window_section_rewind_failed')),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'a Runner that cannot front the hub window says so rather than looking '
    'like it worked',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(settingsRouteChannel, (call) async {
        if (call.method != 'openInHub') return null;
        throw PlatformException(code: 'no-hub-window');
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(settingsRouteChannel, null),
      );

      final services = makeServices(settingsWindow: true);
      addTearDown(services.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            services: services,
            initialSection: SettingsSection.rewind,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('hub_window_section_rewind')));
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const Key('hub_window_section_rewind_failed')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('Scan now is not offered where pressing it would do nothing', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final services = makeServices(settingsWindow: true);
    addTearDown(services.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          services: services,
          initialSection: SettingsSection.personal,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('memory_status_rescan')), findsNothing);
    expect(find.byKey(const Key('memory_status_summary')), findsNothing);
    expect(find.byKey(const Key('hub_window_section_personal')), findsOne);

    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'the hub window opens its own settings route when the Runner hands a '
    'section back to it',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final messenger = tester.binding.defaultBinaryMessenger;
      const windowChrome = MethodChannel('omi/window_chrome');
      const menuBar = MethodChannel('omi/menu_bar');
      messenger.setMockMethodCallHandler(windowChrome, (call) async => null);
      messenger.setMockMethodCallHandler(menuBar, (call) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChrome, null);
        messenger.setMockMethodCallHandler(menuBar, null);
      });

      final services = makeServices(settingsWindow: false);
      addTearDown(services.dispose);
      await tester.pumpWidget(MaterialApp(home: OmiShell(services: services)));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(SettingsScreen), findsNothing);

      await messenger.handlePlatformMessage(
        'omi/window_chrome',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('showSettingsSection', SettingsSection.rewind.name),
        ),
        (_) {},
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final screen = tester.widget<SettingsScreen>(find.byType(SettingsScreen));
      expect(screen.initialSection, SettingsSection.rewind);

      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
