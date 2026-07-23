import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/omi_shell.dart';
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
    'the chord types into the hub while omi is frontmost and summons the '
    'panel from the background',
    (tester) async {
      final harness = await _Harness.pump(tester, makeServices());

      // Frontmost: the chord belongs to the hub's own composer, so no
      // floating panel is summoned over the window it came from.
      harness.emit(const {'type': 'appActivation', 'active': true});
      await tester.pump();
      harness.chord();
      await tester.pump(const Duration(milliseconds: 600));
      expect(harness.chromeCalls, isNot(contains('summonPill')));

      // Background: the same chord summons the panel next to the cursor.
      harness.emit(const {'type': 'appActivation', 'active': false});
      await tester.pump();
      harness.chord();
      await tester.pump(const Duration(milliseconds: 600));
      expect(harness.chromeCalls, contains('summonPill'));

      await harness.close(tester);
    },
  );

  testWidgets('the shake starts voice from the background, chord or not', (
    tester,
  ) async {
    final harness = await _Harness.pump(tester, makeServices());

    harness.emit(const {'type': 'appActivation', 'active': true});
    harness.emit(const {'type': 'shake'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Voice is never rerouted to the composer: it reaches the surface — and
    // its native overlay windows — even while omi is frontmost.
    expect(harness.voiceCalls, contains('start'));

    await harness.close(tester);
  });

  testWidgets('a dead global input tap is reported in the hub', (tester) async {
    final harness = await _Harness.pump(tester, makeServices());

    expect(find.byKey(const Key('global_input_notice')), findsNothing);

    harness.emit(const {
      'type': 'diagnostics',
      'trusted': false,
      'tapInstalled': false,
    });
    await tester.pump();
    expect(find.byKey(const Key('global_input_notice')), findsOne);
    expect(find.textContaining('not granted'), findsOne);

    harness.emit(const {
      'type': 'diagnostics',
      'trusted': true,
      'tapInstalled': true,
    });
    await tester.pump();
    expect(find.byKey(const Key('global_input_notice')), findsNothing);

    await harness.close(tester);
  });
}

final class _Harness {
  _Harness(this.services);

  static const _keyboard = EventChannel('omi/desktop_keyboard');
  static const _windowChrome = MethodChannel('omi/window_chrome');
  static const _voiceOverlay = MethodChannel('omi/voice_overlay');
  static const _pillHost = MethodChannel('omi/pill_host');
  static const _menuBar = MethodChannel('omi/menu_bar');
  static const _keyboardControl = MethodChannel('omi/desktop_keyboard_control');

  final AppServices services;
  final sinks = <MockStreamHandlerEventSink>[];
  final chromeCalls = <String>[];
  final voiceCalls = <String>[];

  static Future<_Harness> pump(
    WidgetTester tester,
    AppServices services,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final harness = _Harness(services);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockStreamHandler(
      _keyboard,
      MockStreamHandler.inline(
        onListen: (arguments, events) => harness.sinks.add(events),
      ),
    );
    messenger.setMockMethodCallHandler(_windowChrome, (call) async {
      harness.chromeCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(_voiceOverlay, (call) async {
      harness.voiceCalls.add(call.method);
      return null;
    });
    for (final channel in [_pillHost, _menuBar, _keyboardControl]) {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
    }
    await tester.pumpWidget(MaterialApp(home: OmiShell(services: services)));
    await tester.pump(const Duration(seconds: 2));
    expect(harness.sinks, isNotEmpty);
    return harness;
  }

  void emit(Map<String, Object?> event) {
    for (final sink in sinks) {
      sink.success(event);
    }
  }

  /// One full physical chord: both Shift keys down, then both released.
  void chord() {
    emit(const {'type': 'shift', 'key': 'left', 'pressed': true});
    emit(const {'type': 'shift', 'key': 'right', 'pressed': true});
    emit(const {'type': 'shift', 'key': 'left', 'pressed': false});
    emit(const {'type': 'shift', 'key': 'right', 'pressed': false});
  }

  Future<void> close(WidgetTester tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockStreamHandler(_keyboard, null);
    for (final channel in [
      _windowChrome,
      _voiceOverlay,
      _pillHost,
      _menuBar,
      _keyboardControl,
    ]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    services.dispose();
    debugDefaultTargetPlatformOverride = null;
  }
}
