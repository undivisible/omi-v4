import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/capture_notifier.dart';
import 'package:omi/features/firmware_update_check.dart';
import 'package:omi/features/mobile_companion_shell.dart';
import 'package:omi/features/transcript_log_store.dart';
import 'package:omi/main.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/onboarding/onboarding_completion.dart';
import 'package:omi/ui/burst_glow.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
  });
  tearDown(() {
    binding.platformDispatcher.clearAccessibilityFeaturesTestValue();
  });

  test('probe connectDevice completes', () async {
    final fixture = await _mobileFixture('user-a');
    final device = await fixture.services
        .connectDevice('omi-1')
        .timeout(const Duration(seconds: 5));
    expect(device.id, 'omi-1');
    fixture.services.dispose();
  });

  testWidgets('mobile platforms route to the companion shell', (tester) async {
    final services = await _authorizedServices('user-a');
    final store = VolatileOnboardingCompletionStore();
    await store.complete('user-a');

    await tester.pumpWidget(
      OmiApp(
        services: services,
        onboardingCompletionStore: store,
        platformOverride: TargetPlatform.iOS,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion_home')), findsOneWidget);
    expect(find.byKey(const Key('chat_input')), findsNothing);
  });

  testWidgets('desktop platforms keep the existing hub shell', (tester) async {
    final services = await _authorizedServices('user-a');
    final store = VolatileOnboardingCompletionStore();
    await store.complete('user-a');

    await tester.pumpWidget(
      OmiApp(
        services: services,
        onboardingCompletionStore: store,
        platformOverride: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat_input')), findsOneWidget);
    expect(find.byKey(const Key('companion_home')), findsNothing);
  });

  testWidgets('pairing flow scans, connects, remembers, and shows status', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');
    final pairedDevices = VolatilePairedDeviceStore();

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: pairedDevices,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion_reconnect')), findsOneWidget);
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    expect(await pairedDevices.read(), 'omi-1');
    expect(find.byKey(const Key('companion_battery_tile')), findsOneWidget);
    expect(find.text('87%'), findsOneWidget);
    expect(find.byKey(const Key('companion_stat_minutes')), findsOneWidget);
    expect(fixture.services.deviceAudio.active, isTrue);

    await tester.longPress(find.byKey(const Key('companion_pendant_tap')));
    await _settle(tester);

    expect(fixture.services.deviceAudio.active, isFalse);
    expect(find.byKey(const Key('companion_reconnect')), findsOneWidget);
    expect(
      find.byKey(const Key('companion_disconnected_label')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);
    expect(find.byKey(const Key('companion_battery_tile')), findsOneWidget);
    fixture.services.dispose();
  });

  testWidgets('session list shows only final transcript segments', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('companion_transcripts_empty')),
      findsOneWidget,
    );

    fixture.hub.events0
      ..add(
        NativeEventTranscriptDelta(
          value: _delta('still speaking', finalSegment: false),
        ),
      )
      ..add(
        NativeEventTranscriptDelta(
          value: _delta('hello from the pendant', finalSegment: true),
        ),
      );
    await tester.pumpAndSettle();

    // The finalized segment shows twice: once as the live strip's latest line
    // under the hero, once as a row in the conversations list.
    expect(find.text('hello from the pendant'), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byKey(const Key('companion_live_transcript')),
        matching: find.text('hello from the pendant'),
      ),
      findsOneWidget,
    );
    expect(find.text('still speaking'), findsNothing);
    expect(find.byKey(const Key('companion_transcripts_empty')), findsNothing);
    fixture.services.dispose();
  });

  testWidgets('the live transcript strip renders interim speech under the '
      'hero', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    fixture.hub.events0.add(
      NativeEventTranscriptDelta(
        value: _delta('halfway through a word', finalSegment: false),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('companion_live_transcript')),
        matching: find.text('halfway through a word'),
      ),
      findsOneWidget,
    );
    // Interim text never reaches the conversations list.
    expect(find.text('halfway through a word'), findsOneWidget);

    fixture.hub.events0.add(
      NativeEventTranscriptDelta(
        value: _delta('halfway through a word', finalSegment: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('halfway through a word'), findsNWidgets(2));
    fixture.services.dispose();
  });

  testWidgets('captured transcripts survive recreating the shell with the '
      'same store', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');
    final transcriptLog = VolatileTranscriptLogStore();

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
          transcriptLog: transcriptLog,
        ),
      ),
    );
    await tester.pumpAndSettle();

    fixture.hub.events0.add(
      NativeEventTranscriptDelta(
        value: _delta('persisted segment', finalSegment: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('persisted segment'), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
          transcriptLog: transcriptLog,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('persisted segment'), findsNWidgets(2));
    expect(find.byKey(const Key('companion_transcripts_empty')), findsNothing);
    fixture.services.dispose();
  });

  test(
    'transcript log store round-trips segments through preferences',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = PreferencesTranscriptLogStore();
      await store.save([
        _delta(
          'from the pendant',
          finalSegment: true,
          speaker: 2,
          channelIndex: 0,
        ),
      ]);

      final restored = await PreferencesTranscriptLogStore().read();

      expect(restored, hasLength(1));
      expect(restored.single.text, 'from the pendant');
      expect(restored.single.finalSegment, isTrue);
      expect(restored.single.deviceId, 'omi-1');
      expect(restored.single.speaker, 2);
      expect(restored.single.channelIndex, 0);
    },
  );

  testWidgets('disconnected state collapses to one block with reconnect', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion_pendant_faded')), findsOneWidget);
    expect(
      find.byKey(const Key('companion_disconnected_label')),
      findsOneWidget,
    );
    expect(find.text('Omi disconnected'), findsOneWidget);
    expect(find.byKey(const Key('companion_reconnect')), findsOneWidget);
    expect(find.byKey(const Key('companion_scan_tile')), findsNothing);
    expect(find.byKey(const Key('companion_remembered_tile')), findsNothing);
    expect(find.byKey(const Key('companion_connection_tile')), findsNothing);
    fixture.services.dispose();
  });

  testWidgets('pendant page scrolls and bounds the session list', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final sections = tester.widget<CustomScrollView>(
      find.byKey(const Key('companion_page_sections')),
    );
    expect(sections.physics, isNot(isA<NeverScrollableScrollPhysics>()));
    expect(find.byKey(const Key('companion_session_list')), findsOneWidget);
    fixture.services.dispose();
  });

  testWidgets('only the hero blurs and fades as the page scrolls', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var index = 0; index < 6; index++) {
      fixture.hub.events0.add(
        NativeEventTranscriptDelta(
          value: _delta('segment $index', finalSegment: true),
        ),
      );
    }
    await tester.pumpAndSettle();

    final fade = find.byKey(const Key('companion_hero_fade'));
    expect(tester.widget<Opacity>(fade).opacity, 1);
    expect(find.byType(ImageFiltered), findsNothing);

    await tester.drag(
      find.byKey(const Key('companion_page_sections')),
      const Offset(0, -110),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<Opacity>(fade).opacity, lessThan(1));
    expect(tester.widget<Opacity>(fade).opacity, greaterThan(0));
    // The blur wraps only the hero, so the sections below scroll crisply.
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ImageFiltered),
        matching: find.byKey(const Key('companion_pendant_image')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ImageFiltered),
        matching: find.byKey(const Key('companion_session_list')),
      ),
      findsNothing,
    );
    fixture.services.dispose();
  });

  testWidgets('the pendant image starts flush with the top of the screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 59),
              viewPadding: const EdgeInsets.only(top: 59),
            ),
            child: MobileCompanionShell(
              services: fixture.services,
              pairedDevices: VolatilePairedDeviceStore(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The cord has to reach past the notch, so the hero deliberately drops the
    // top safe-area inset the rest of the page still respects.
    final top = tester
        .getTopLeft(find.byKey(const Key('companion_pendant_image')))
        .dy;
    expect(top, lessThan(1));
    fixture.services.dispose();
  });

  testWidgets('capture runs as soon as the pendant connects, with no tap on '
      'the image', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    expect(fixture.services.deviceAudio.active, isTrue);
    expect(find.byKey(const Key('companion_capture_ring')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('companion_pendant_hint'))).data,
      'Capturing · Hold the pendant to disconnect',
    );

    // Tapping the pendant image no longer does anything: capture is owned by
    // the switch below the minutes chip.
    await tester.tap(find.byKey(const Key('companion_pendant_tap')));
    await _settle(tester);

    expect(fixture.services.deviceAudio.active, isTrue);
    expect(find.byKey(const Key('companion_capture_ring')), findsOneWidget);
    fixture.services.dispose();
  });

  testWidgets('the capture switch sits under the minutes chip and stops and '
      'restarts capture', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');
    final captureEnabled = VolatileCaptureEnabledStore();

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
          captureEnabledStore: captureEnabled,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    final chip = tester.getBottomLeft(
      find.byKey(const Key('companion_stat_minutes')),
    );
    final toggle = tester.getTopLeft(
      find.byKey(const Key('companion_capture_toggle')),
    );
    expect(toggle.dy, greaterThanOrEqualTo(chip.dy));

    await tester.tap(find.byKey(const Key('companion_capture_switch')));
    await _settle(tester);

    expect(fixture.services.deviceAudio.active, isFalse);
    expect(captureEnabled.enabled, isFalse);
    expect(find.byKey(const Key('companion_capture_ring')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const Key('companion_pendant_hint'))).data,
      'Capture is off · Hold the pendant to disconnect',
    );

    await tester.tap(find.byKey(const Key('companion_capture_switch')));
    await _settle(tester);

    expect(fixture.services.deviceAudio.active, isTrue);
    expect(captureEnabled.enabled, isTrue);
    expect(find.byKey(const Key('companion_capture_ring')), findsOneWidget);
    fixture.services.dispose();
  });

  testWidgets('a remembered capture-off choice keeps capture off when the '
      'pendant connects', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
          captureEnabledStore: VolatileCaptureEnabledStore(enabled: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    expect(fixture.services.deviceAudio.active, isFalse);
    expect(find.byKey(const Key('companion_capture_ring')), findsNothing);
    fixture.services.dispose();
  });

  // The regression the pendant surfaced as "capture always says off": the
  // remembered-device reconnect starts capture without anything calling
  // setState afterwards, so a hero that samples `deviceAudio.active` only while
  // it happens to rebuild renders the whole session as idle.
  testWidgets('capture reads as on after the remembered pendant reconnects on '
      'its own', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');
    final paired = VolatilePairedDeviceStore();
    await paired.save('omi-1');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: paired,
        ),
      ),
    );
    await _settle(tester);

    expect(fixture.services.deviceAudio.active, isTrue);
    expect(find.byKey(const Key('companion_capture_ring')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('companion_pendant_hint'))).data,
      'Capturing · Hold the pendant to disconnect',
    );
    fixture.services.dispose();
  });

  testWidgets('the pendant LED is driven for a capture nobody switched on', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final led = _LedAdapter();
    final fixture = await _mobileFixture('user-a', adapter: led);
    final paired = VolatilePairedDeviceStore();
    await paired.save('omi-1');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: paired,
          captureEnabledStore: VolatileCaptureEnabledStore(),
        ),
      ),
    );
    await _settle(tester);

    expect(led.ledWrites, contains(true));
    expect(
      find.byKey(const Key('companion_capture_led_unsupported')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('companion_capture_switch')));
    await _settle(tester);

    expect(led.ledWrites.last, isFalse);
    fixture.services.dispose();
  });

  testWidgets('firmware without the capture-LED characteristic stops claiming '
      'the pendant light follows the switch', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final led = _LedAdapter(ledSupported: false);
    final fixture = await _mobileFixture('user-a', adapter: led);
    final paired = VolatilePairedDeviceStore();
    await paired.save('omi-1');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: paired,
        ),
      ),
    );
    await _settle(tester);

    // The LED cannot be driven, but the app-side capture state is still right.
    expect(led.ledWrites, isEmpty);
    expect(fixture.services.deviceAudio.active, isTrue);
    expect(find.byKey(const Key('companion_capture_ring')), findsOneWidget);
    expect(
      find.byKey(const Key('companion_capture_led_unsupported')),
      findsOneWidget,
    );
    fixture.services.dispose();
  });

  testWidgets('connecting warms the pendant image and bursts the glow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    binding.platformDispatcher.clearAccessibilityFeaturesTestValue();
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
          captureEnabledStore: VolatileCaptureEnabledStore(),
        ),
      ),
    );
    // The pendant sways forever with motion on, so nothing here can settle.
    await _pumpFrames(tester);

    // Disconnected: grey, dimmed, and no burst.
    expect(find.byKey(const Key('companion_pendant_faded')), findsOneWidget);
    expect(find.byType(OmiBurstGlow), findsNothing);

    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _pumpFrames(tester);

    expect(find.byType(OmiBurstGlow), findsOneWidget);

    // Partway through the warm-up the image is neither ghost nor asset.
    final midway = tester.widget<Opacity>(
      find.byKey(const Key('companion_pendant_faded')),
    );
    expect(midway.opacity, greaterThan(.35));
    expect(midway.opacity, lessThan(1));

    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const Key('companion_pendant_faded')), findsNothing);

    // Disconnecting runs the same ramp backwards and retires the burst.
    await tester.longPress(find.byKey(const Key('companion_pendant_tap')));
    await _pumpFrames(tester);

    expect(find.byType(OmiBurstGlow), findsNothing);
    final cooling = tester.widget<Opacity>(
      find.byKey(const Key('companion_pendant_faded')),
    );
    expect(cooling.opacity, lessThan(1));
    fixture.services.dispose();
  });

  testWidgets('the connect burst is inert under reduced motion', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
          captureEnabledStore: VolatileCaptureEnabledStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    // disableAnimations is on for the whole suite: the pendant lands warm in
    // one frame and nothing bursts.
    expect(find.byType(OmiBurstGlow), findsNothing);
    expect(find.byKey(const Key('companion_pendant_faded')), findsNothing);
    fixture.services.dispose();
  });

  testWidgets('the capture switch posts a local notification when it '
      'restarts capture', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');
    final notifier = _RecordingCaptureNotifier();

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
          captureNotifier: notifier,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    expect(notifier.started, isEmpty);

    await tester.tap(find.byKey(const Key('companion_capture_switch')));
    await _settle(tester);
    expect(notifier.started, isEmpty);
    expect(notifier.stopped, 1);

    await tester.tap(find.byKey(const Key('companion_capture_switch')));
    await _settle(tester);

    expect(notifier.started, ['Omi Pendant']);
    fixture.services.dispose();
  });

  testWidgets('holding the pendant image disconnects', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);
    expect(fixture.services.deviceAudio.active, isTrue);

    await tester.longPress(find.byKey(const Key('companion_pendant_tap')));
    await _settle(tester);

    expect(fixture.services.deviceAudio.active, isFalse);
    expect(
      find.byKey(const Key('companion_disconnected_label')),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('companion_pendant_hint'))).data,
      'Reconnect to control your Omi',
    );
    fixture.services.dispose();
  });

  testWidgets('every mobile settings row is tappable across its full width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();

    // No row carries its own trailing button: the row is the button.
    expect(
      find.descendant(
        of: find.byKey(const Key('companion_settings_sheet')),
        matching: find.byType(IconButton),
      ),
      findsNothing,
    );

    for (final key in const [
      'companion_sign_out',
      'companion_settings_disconnect',
      'companion_sleep_device',
      'companion_remembered_tile',
      'companion_developer_options',
      'companion_reset_pendant',
      'companion_delete_account',
    ]) {
      final row = find.byKey(Key(key));
      expect(row, findsOneWidget, reason: '$key is missing');
      final tile = tester.widget<ListTile>(
        find.descendant(of: row, matching: find.byType(ListTile)),
      );
      expect(tile.onTap, isNotNull, reason: '$key is not tappable');
      // The tap target spans the row, not just a trailing control.
      expect(
        tester
            .getSize(find.descendant(of: row, matching: find.byType(InkWell)))
            .width,
        closeTo(tester.getSize(row).width, 1),
        reason: '$key does not span the full row',
      );
    }
    fixture.services.dispose();
  });

  testWidgets('the settings sheet is dismissed by dragging down at the top', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('companion_settings_sheet')), findsOneWidget);

    final list = tester.widget<ListView>(
      find.byKey(const Key('companion_settings_sheet')),
    );
    expect(list.controller!.offset, 0);

    await tester.drag(
      find.byKey(const Key('companion_settings_sheet')),
      const Offset(0, 600),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion_settings_sheet')), findsNothing);
    fixture.services.dispose();
  });

  testWidgets('mobile settings drop the processing-consent and transcription-'
      'route rows without blocking capture', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    // Capture is gated on processing authority, so the tile going away must
    // not take the receipt with it.
    expect(
      fixture.services.auth.snapshot.hasProcessingAuthority,
      isTrue,
      reason: 'consent still authorizes capture',
    );
    expect(fixture.services.deviceAudio.active, isTrue);

    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion_consent_tile')), findsNothing);
    expect(find.byKey(const Key('companion_revoke_consent')), findsNothing);
    expect(find.byKey(const Key('companion_route_tile')), findsNothing);
    expect(find.text('Processing consent'), findsNothing);
    expect(find.text('Transcription route'), findsNothing);
    fixture.services.dispose();
  });

  testWidgets('a missing consent receipt is re-established so capture is '
      'never stuck without the settings tile', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Signed in, but the stored receipt is gone — a reinstall, a cleared
    // preference store, or a persistence failure.
    final auth = AuthController(
      _Gateway(_session('user-a')),
      consentStore: VolatileConsentStore(),
    );
    await auth.setConsent(true);
    await auth.signIn(AuthProvider.google);
    expect(auth.snapshot.hasProcessingAuthority, isFalse);

    final services = AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: _Adapter(),
      ),
      auth: auth,
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(auth.snapshot.hasProcessingAuthority, isTrue);
    services.dispose();
  });

  testWidgets('the desktop install row is the tap target, with its own '
      'dismiss control', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');
    final opened = <Uri>[];

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
          openLink: (uri) async => opened.add(uri),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.byKey(const Key('companion_desktop_notice_tile'));
    expect(tile, findsOneWidget);
    expect(find.text('Install the Omi desktop app'), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(
            find.descendant(of: tile, matching: find.byType(ListTile)),
          )
          .onTap,
      isNotNull,
    );

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(tile, findsNothing);
    fixture.services.dispose();
  });

  testWidgets('the connected state has exactly one connection indicator', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    expect(find.textContaining('Connected'), findsOneWidget);
    expect(find.byKey(const Key('companion_connection_tile')), findsNothing);
    expect(find.byKey(const Key('companion_capture_tile')), findsNothing);
    fixture.services.dispose();
  });

  testWidgets('firmware details live only in developer options', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    expect(find.text('1.0.3'), findsNothing);
    expect(find.text('Opus 16 kHz'), findsNothing);
    expect(find.textContaining('dBm'), findsNothing);

    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('companion_developer_options')),
    );
    await tester.tap(find.byKey(const Key('companion_developer_options')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('companion_developer_options_page')),
      findsOneWidget,
    );
    expect(find.text('1.0.3'), findsOneWidget);
    expect(find.text('Opus 16 kHz'), findsOneWidget);
    expect(find.text('-52 dBm'), findsOneWidget);
    expect(
      find.byKey(const Key('companion_dev_segments_tile')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('companion_dev_capture_tile')), findsOneWidget);
    // The update row is hidden for this pendant (no SMP service), so developer
    // options is where that stops being a silent absence.
    expect(
      tester
          .widget<ListTile>(
            find.descendant(
              of: find.byKey(const Key('companion_dev_dfu_tile')),
              matching: find.byType(ListTile),
            ),
          )
          .subtitle,
      isA<Padding>(),
    );
    expect(find.textContaining('Unavailable: this firmware'), findsOneWidget);
    fixture.services.dispose();
  });

  testWidgets('renaming writes through the relay and refreshes the name', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adapter = _RenamingAdapter();
    final fixture = await _mobileFixture('user-a', adapter: adapter);

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('companion_rename_device')), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('companion_rename_device')),
    );
    await tester.tap(find.byKey(const Key('companion_rename_device')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('companion_rename_field')),
      'Studio Omi',
    );
    await tester.tap(find.byKey(const Key('companion_rename_confirm')));
    await tester.pumpAndSettle();

    expect(adapter.renames, ['Studio Omi']);
    fixture.services.dispose();
  });

  testWidgets('settings degrade gracefully when the firmware lacks the '
      'control characteristics', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    // The stock fake adapter implements none of the settings-service writes,
    // standing in for a pendant on firmware that predates 19b10014-16.
    expect(fixture.services.deviceRelay.supportsRename, isFalse);
    expect(await fixture.services.deviceRelay.renameDevice('nope'), isFalse);
    expect(await fixture.services.deviceRelay.sleepDevice(), isFalse);
    expect(await fixture.services.deviceRelay.writeCaptureLed(true), isFalse);

    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion_rename_device')), findsNothing);
    expect(
      find.byKey(const Key('companion_settings_disconnect')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('companion_developer_options')),
      findsOneWidget,
    );
    fixture.services.dispose();
  });

  testWidgets('a pendant that cannot take an OTA never sees the firmware '
      'row', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
          captureEnabledStore: VolatileCaptureEnabledStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion_firmware_update')), findsNothing);
    fixture.services.dispose();
  });

  testWidgets('the firmware screen offers the update and refuses to flash '
      'while capture streams', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a', adapter: _DfuAdapter());

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
          captureEnabledStore: VolatileCaptureEnabledStore(),
          firmwareChecker: _firmwareChecker(),
          firmwareDownloader: _ZipDownloader(),
          firmwareFlasher: _FakeFlasher(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('companion_firmware_update')),
    );
    await tester.tap(find.byKey(const Key('companion_firmware_update')));
    await _settle(tester);

    expect(find.byKey(const Key('companion_firmware_page')), findsOneWidget);
    expect(
      find.byKey(const Key('companion_firmware_available')),
      findsOneWidget,
    );
    // Capture is streaming, so the screen says so instead of offering a flash.
    expect(
      tester
          .widget<ListTile>(
            find.descendant(
              of: find.byKey(const Key('companion_firmware_block')),
              matching: find.byType(ListTile),
            ),
          )
          .title,
      isA<Text>().having((text) => text.data, 'title', 'Not ready to update'),
    );
    expect(find.byKey(const Key('companion_firmware_install')), findsNothing);
    fixture.services.dispose();
  });

  testWidgets('a waiting firmware update rides the same banner card as the '
      'desktop invitation, and dismisses', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final fixture = await _mobileFixture('user-a', adapter: _DfuAdapter());

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
          captureEnabledStore: VolatileCaptureEnabledStore(),
          firmwareChecker: _firmwareChecker(),
          firmwareDownloader: _ZipDownloader(),
          firmwareFlasher: _FakeFlasher(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    final banner = find.byKey(const Key('companion_firmware_notice_tile'));
    expect(banner, findsOneWidget);
    // Same component, same slot: the pendant notice sits directly above the
    // desktop one rather than on a screen of its own.
    expect(
      tester.getTopLeft(banner).dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const Key('companion_desktop_notice_tile')))
            .dy,
      ),
    );

    await tester.tap(
      find.byKey(const Key('companion_firmware_notice_dismiss')),
    );
    await _settle(tester);

    expect(banner, findsNothing);
    fixture.services.dispose();
  });

  testWidgets('the banner opens the flow, which writes the package and '
      'confirms the version that comes back', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final adapter = _DfuAdapter();
    final flasher = _FakeFlasher(onDone: () => adapter.revision = '9.9.9');
    final fixture = await _mobileFixture('user-a', adapter: adapter);

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
          // Capture off, so the pre-flight gate lets the install through.
          captureEnabledStore: VolatileCaptureEnabledStore(enabled: false),
          firmwareChecker: _firmwareChecker(),
          firmwareDownloader: _ZipDownloader(),
          firmwareFlasher: flasher,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('companion_firmware_notice_tile')));
    await _settle(tester);

    expect(find.byKey(const Key('companion_firmware_page')), findsOneWidget);
    await tester.tap(find.byKey(const Key('companion_firmware_install')));
    // The install does real file I/O and waits for the BLE stack to release
    // the peripheral, so it needs several real-time windows rather than one.
    await _settleSlow(tester);

    expect(flasher.flashed.single.single.image, 0);
    expect(
      tester
          .widget<Text>(
            find.byKey(const Key('companion_firmware_progress_label')),
          )
          .data,
      'Installed',
    );
    fixture.services.dispose();
  });

  testWidgets('the settings disconnect action stops capture', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('companion_settings_disconnect')),
    );
    await tester.tap(find.byKey(const Key('companion_settings_disconnect')));
    await _settle(tester);

    expect(fixture.services.deviceAudio.active, isFalse);
    fixture.services.dispose();
  });

  testWidgets('pendant glow is present and its stack does not clip', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final glow = find.byKey(const Key('companion_pendant_glow'));
    expect(glow, findsOneWidget);
    final heroStack = tester.widget<Stack>(
      find.ancestor(of: glow, matching: find.byType(Stack)).first,
    );
    expect(heroStack.clipBehavior, Clip.none);
    fixture.services.dispose();
  });

  testWidgets('app follows the system theme mode', (tester) async {
    final services = await _authorizedServices('user-a');
    final store = VolatileOnboardingCompletionStore();
    await store.complete('user-a');

    await tester.pumpWidget(
      OmiApp(
        services: services,
        onboardingCompletionStore: store,
        platformOverride: TargetPlatform.iOS,
      ),
    );
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    expect(app.theme?.brightness, Brightness.light);
    expect(app.darkTheme?.brightness, Brightness.dark);
  });

  testWidgets('companion shell adapts its background to dark mode', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData(brightness: Brightness.dark),
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scaffold = tester.widget<Scaffold>(
      find.byKey(const Key('companion_home')),
    );
    expect(scaffold.backgroundColor, const Color(0xff171716));
    fixture.services.dispose();
  });

  testWidgets('delete account confirms, calls the worker, and signs out', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final requests = <({String method, String path})>[];
    final worker = WorkerHttpClient(
      baseUri: Uri.parse('https://api.example.test'),
      sessionProvider: () async => _session('user-a'),
      client: MockClient((request) async {
        requests.add((method: request.method, path: request.url.path));
        return http.Response('', 204);
      }),
    );
    final fixture = await _mobileFixture('user-a', worker: worker);

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion_delete_account')), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('companion_delete_account')),
    );
    await tester.tap(find.byKey(const Key('companion_delete_account')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('companion_delete_account_confirm')),
      findsOneWidget,
    );
    expect(requests, isEmpty);
    await tester.tap(find.byKey(const Key('companion_delete_account_confirm')));
    await tester.pumpAndSettle();

    expect(requests, [(method: 'DELETE', path: '/v1/account')]);
    expect(fixture.services.auth.snapshot.session, isNull);
    fixture.services.dispose();
  });

  testWidgets('reset pendant confirms, forgets, and disconnects', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');
    final pairedDevices = VolatilePairedDeviceStore();

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: pairedDevices,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reconnect')));
    await _settle(tester);
    expect(await pairedDevices.read(), 'omi-1');

    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('companion_reset_pendant')),
    );
    await tester.tap(find.byKey(const Key('companion_reset_pendant')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_reset_pendant_confirm')));
    await _settle(tester);

    expect(await pairedDevices.read(), isNull);
    expect(fixture.services.deviceAudio.active, isFalse);
    fixture.services.dispose();
  });

  testWidgets('settings sheet opens from the top-right button', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion_account_tile')), findsNothing);
    expect(find.byKey(const Key('companion_settings_button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion_settings_sheet')), findsOneWidget);
    expect(find.byKey(const Key('companion_account_tile')), findsOneWidget);
    expect(find.byKey(const Key('companion_version_tile')), findsOneWidget);
    expect(find.byKey(const Key('companion_sign_out')), findsOneWidget);
    expect(
      find.byKey(const Key('companion_eventkit_proactive_sync')),
      findsOneWidget,
    );
    fixture.services.dispose();
  });

  testWidgets('the Calendar & Reminders row sits on the same paper card as '
      'every other mobile row', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _mobileFixture('user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: fixture.services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('companion_settings_button')));
    await tester.pumpAndSettle();

    final card = find
        .ancestor(
          of: find.byKey(const Key('companion_eventkit_proactive_sync')),
          matching: find.byType(DecoratedBox),
        )
        .first;
    final decoration =
        tester.widget<DecoratedBox>(card).decoration as BoxDecoration;
    expect(decoration.color, const Color(0xfffffefa));
    expect(decoration.border, isNotNull);
    expect(decoration.borderRadius, isNotNull);
    fixture.services.dispose();
  });

  testWidgets('signed-in pendant page lists currents tasks with complete', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final auth = await _authorizedAuth('user-a');
    final transport = _CurrentsTransport();
    final services = AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: _Adapter(),
      ),
      auth: auth,
      currentsClient: CurrentsClient(transport),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('TASKS'), findsOneWidget);
    expect(find.byKey(const Key('companion_task_current-1')), findsOneWidget);
    expect(find.text('Reply to Sam'), findsOneWidget);

    await tester.tap(find.byKey(const Key('companion_task_current-1')));
    await tester.pumpAndSettle();

    expect(transport.feedbackKinds, ['dismissed']);
    expect(find.text('TASKS'), findsNothing);
    services.dispose();
  });

  testWidgets('signed-out pendant page skips the tasks section', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final services = AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: _Adapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      currentsClient: CurrentsClient(_CurrentsTransport()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MobileCompanionShell(
          services: services,
          pairedDevices: VolatilePairedDeviceStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('TASKS'), findsNothing);
    services.dispose();
  });
}

// Device work hops between the fake test clock and real async (stream
// cancellation, the native hub's acknowledgement round-trips), so give it a
// few real turns and pump between each one before asserting.
// The motion-enabled sibling of [_settle]: with animations on the pendant sway
// never ends, so advance a fixed number of frames instead of settling.
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var round = 0; round < 3; round += 1) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

// For flows that step through real file I/O and a real delay: each round gives
// the event loop a window, and pumps whatever came back out of it.
Future<void> _settleSlow(WidgetTester tester) async {
  for (var round = 0; round < 30; round += 1) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    // Plain pumps, not pumpAndSettle: an indeterminate progress bar never
    // settles, and one is on screen for most of this flow. The step also has
    // to move the fake clock past the installer's own settle delay.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 3; round += 1) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }
}

final class _CurrentsTransport implements CurrentsTransport {
  final feedbackKinds = <String>[];
  var _dismissed = false;

  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async {
    if (request.path == '/v1/currents/generate') {
      return const CurrentsResponse(statusCode: 200, body: <String, Object?>{});
    }
    if (request.path == '/v1/currents') {
      return CurrentsResponse(
        statusCode: 200,
        body: {
          'currents': [if (!_dismissed) _card('surfaced', null)],
        },
      );
    }
    if (request.path == '/v1/currents/current-1/feedback') {
      feedbackKinds.add(request.body!['kind']! as String);
      _dismissed = true;
      return CurrentsResponse(
        statusCode: 200,
        body: {'current': _card('dismissed', 'feedback-1')},
      );
    }
    return const CurrentsResponse(statusCode: 404, body: {'error': 'missing'});
  }

  Map<String, Object?> _card(String status, String? feedbackReference) => {
    'id': 'current-1',
    'status': status,
    'evidence': [
      {'sourceId': 'src-1', 'reason': 'observed'},
    ],
    'reason': 'Sam is waiting on a reply',
    'timing': {'surfaceAt': '2026-07-22T08:00:00Z'},
    'confidence': 0.9,
    'proposedNextStep': 'Reply to Sam about the handoff',
    'createdAt': '2026-07-22T07:00:00Z',
    'updatedAt': '2026-07-22T07:00:00Z',
    'feedbackReference': feedbackReference,
    'title': 'Reply to Sam',
    'summary': 'Sam asked about the handoff yesterday.',
    'sourceKind': 'telegram',
  };
}

TranscriptDelta _delta(
  String text, {
  required bool finalSegment,
  int? speaker,
  int? channelIndex,
}) => TranscriptDelta(
  requestId: 'start-req',
  audioStreamId: 'stream-1',
  segmentId: 'segment-$text',
  segmentSequence: Uint64.fromBigInt(BigInt.zero),
  sttEpoch: 0,
  deviceId: 'omi-1',
  provider: 'managed',
  startMs: 0,
  endMs: 1,
  occurredAtMs: DateTime.utc(2026, 7, 22).millisecondsSinceEpoch,
  text: text,
  finalSegment: finalSegment,
  speaker: speaker,
  channelIndex: channelIndex,
);

AuthSession _session(String uid) =>
    AuthSession(uid: uid, idToken: 'token-$uid', expiresAt: DateTime.utc(2030));

Future<AuthController> _authorizedAuth(String uid) async {
  final auth = AuthController(
    _Gateway(_session(uid)),
    consentStore: VolatileConsentStore(),
  );
  await auth.setConsent(true);
  await auth.grantProcessingConsent();
  return auth;
}

Future<AppServices> _authorizedServices(String uid) async {
  final auth = await _authorizedAuth(uid);
  return AppServices.forTesting(
    nativeHub: const UnavailableNativeHub('test'),
    deviceRelay: DeviceRelayService(
      role: DeviceRelayRole.desktopObserver,
      adapter: const UnavailableDeviceRelayAdapter(),
    ),
    auth: auth,
    memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
  );
}

Future<({AppServices services, _Hub hub, _Adapter adapter})> _mobileFixture(
  String uid, {
  WorkerHttpClient? worker,
  _Adapter? adapter,
}) async {
  final auth = await _authorizedAuth(uid);
  final hub = _Hub();
  adapter ??= _Adapter();
  final services = AppServices.forTesting(
    nativeHub: hub,
    deviceRelay: DeviceRelayService(
      role: DeviceRelayRole.mobileOwner,
      adapter: adapter,
    ),
    auth: auth,
    worker: worker,
    memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    managedStt: _ManagedStt(
      ManagedSttSession(
        websocketUrl: 'wss://api.example.test/v1/stt/sessions/s/stream',
        session: _session(uid),
      ),
    ),
  );
  await services.initialize();
  return (services: services, hub: hub, adapter: adapter);
}

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

final class _ManagedStt implements ManagedSttClient {
  _ManagedStt(this.result);

  final ManagedSttSession result;

  @override
  Uri get trustedWorkerOrigin => Uri.parse('https://api.example.test/');

  @override
  Future<ManagedSttSession> createSession({
    required String idempotencyKey,
    required String deviceId,
    required String language,
    required ManagedSttEncoding encoding,
    required int sampleRate,
    required int channels,
  }) async => result;
}

final class _Adapter implements DeviceRelayAdapter {
  int connectCalls = 0;
  final _snapshots = StreamController<DeviceRelaySnapshot>.broadcast();
  final _audio = StreamController<List<int>>.broadcast();
  final _connections = StreamController<bool>.broadcast();

  static const _device = RelayDevice(
    id: 'omi-1',
    name: 'Omi Pendant',
    signalStrength: -52,
    batteryLevel: 87,
    firmwareRevision: '1.0.3',
    audioCodec: DeviceAudioCodec.opus,
  );

  @override
  DeviceRelayCapabilities get capabilities => const DeviceRelayCapabilities(
    pairing: DeviceCapabilityState.available,
    metadata: DeviceCapabilityState.available,
    audioStreaming: DeviceCapabilityState.available,
  );

  @override
  Stream<DeviceRelaySnapshot> get snapshots => _snapshots.stream;

  @override
  Future<List<RelayDevice>> scan() async => const [_device];

  @override
  Future<RelayDevice> connect(String deviceId) async {
    connectCalls += 1;
    _snapshots.add(
      DeviceRelaySnapshot(
        phase: DeviceConnectionPhase.connected,
        capabilities: capabilities,
        device: _device,
      ),
    );
    return _device;
  }

  @override
  Future<void> disconnect() async {
    _snapshots.add(
      DeviceRelaySnapshot(
        phase: DeviceConnectionPhase.disconnected,
        capabilities: capabilities,
      ),
    );
  }

  @override
  Stream<List<int>> audioPackets(String deviceId) => _audio.stream;

  @override
  Stream<bool> connectionState(String deviceId) => _connections.stream;
}

// Stands in for a pendant on firmware that exposes the settings service, so
// the rename write has somewhere to land.
final class _RenamingAdapter extends _Adapter implements DeviceRelayRename {
  final renames = <String>[];
  bool accepts = true;

  @override
  Future<bool> renameDevice(String name) async {
    if (!accepts) return false;
    renames.add(name);
    return true;
  }
}

FirmwareUpdateChecker _firmwareChecker() => FirmwareUpdateChecker(
  endpoint: 'https://example.test/releases',
  client: MockClient(
    (request) async => http.Response(
      jsonEncode([
        {
          'tag_name': 'firmware-v9.9.9',
          'html_url': 'https://example.test/firmware-v9.9.9',
          'assets': [
            {
              'name': 'dfu_application.zip',
              'browser_download_url':
                  'https://example.test/dfu_application.zip',
            },
          ],
        },
      ]),
      200,
    ),
  ),
);

// The download is exercised for real in firmware_update_check_test; here it
// only has to put a package on disk that the install flow can unpack.
final class _ZipDownloader implements FirmwareDownloader {
  final requested = <String>[];

  @override
  Future<File> download(
    FirmwareRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    requested.add(release.assetName);
    onProgress?.call(.5);
    onProgress?.call(1);
    final archive = Archive();
    final manifest = utf8.encode(
      jsonEncode({
        'format-version': 0,
        'time': 1,
        'files': [
          {'file': 'app_update.bin', 'image_index': '0'},
        ],
      }),
    );
    archive.add(ArchiveFile('manifest.json', manifest.length, manifest));
    archive.add(ArchiveFile('app_update.bin', 4, const [1, 2, 3, 4]));
    final directory = await Directory.systemTemp.createTemp('omi-widget-dfu');
    final file = File('${directory.path}/${release.assetName}');
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return file;
  }
}

// Stands in for mcumgr: reports progress, then reports success without
// touching a radio.
final class _FakeFlasher implements FirmwareFlasher {
  _FakeFlasher({this.onDone});

  final void Function()? onDone;
  final flashed = <List<FirmwareImage>>[];

  @override
  Stream<FirmwareFlashProgress> flash({
    required String deviceId,
    required List<FirmwareImage> images,
  }) async* {
    flashed.add(images);
    yield const FirmwareFlashProgress(FirmwareFlashStage.uploading, .5);
    yield const FirmwareFlashProgress(FirmwareFlashStage.uploading, 1);
    onDone?.call();
  }
}

// A pendant whose firmware carries the SMP service, so it can take an update
// over BLE. Its reported revision moves when the fake flash lands, which is
// what the post-flash confirmation reads.
final class _DfuAdapter extends _Adapter implements DeviceRelayDfu {
  String revision = '1.0.3';

  RelayDevice get _dfuDevice => const RelayDevice(
    id: 'omi-1',
    name: 'Omi Pendant',
    signalStrength: -52,
    batteryLevel: 87,
    audioCodec: DeviceAudioCodec.opus,
  ).copyWith(firmwareRevision: revision);

  @override
  bool get dfuSupported => true;

  @override
  Future<List<RelayDevice>> scan() async => [_dfuDevice];

  @override
  Future<RelayDevice> connect(String deviceId) async {
    connectCalls += 1;
    final device = _dfuDevice;
    _snapshots.add(
      DeviceRelaySnapshot(
        phase: DeviceConnectionPhase.connected,
        capabilities: capabilities,
        device: device,
      ),
    );
    return device;
  }
}

// A pendant whose firmware may or may not carry 19b10015. With [ledSupported]
// false it refuses every write, exactly as a pre-capture-LED build does.
final class _LedAdapter extends _Adapter implements DeviceRelayLed {
  _LedAdapter({this.ledSupported = true});

  final bool ledSupported;
  final ledWrites = <bool>[];

  @override
  bool get captureLedSupported => ledSupported;

  @override
  Future<bool> writeCaptureLed(bool capturing) async {
    if (!ledSupported) return false;
    ledWrites.add(capturing);
    return true;
  }
}

final class _RecordingCaptureNotifier implements CaptureNotifier {
  final started = <String>[];
  int stopped = 0;

  @override
  Future<void> captureStarted({required String deviceName}) async =>
      started.add(deviceName);

  @override
  Future<void> captureStopped() async => stopped += 1;
}

final class _Hub implements NativeHub {
  final events0 = StreamController<NativeEvent>.broadcast();

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => events0.stream;

  @override
  Future<void> initialize() async {}

  @override
  void configureMemory({
    required String requestId,
    required String databasePath,
    required String tenantId,
    required String personId,
  }) {}

  @override
  void capture({
    required String requestId,
    required String ingestionKey,
    required CaptureSource source,
    required int occurredAtMs,
    required int recordedAtMs,
    String? text,
    String? application,
    String? windowTitle,
    TranscriptLocator? transcriptLocator,
  }) {}

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  }) {}

  @override
  void exportMemory({
    required String requestId,
    int afterCommit = 0,
    int afterEventIndex = -1,
    int? highWaterMark,
    int limit = 100,
  }) {}

  @override
  void listMemoryItems({required String requestId, int limit = 50}) {}

  @override
  void correctMemory({
    required String requestId,
    required String claimId,
    required String text,
    required String value,
    required int occurredAtMs,
    required int recordedAtMs,
  }) {}

  @override
  void deleteMemorySource({
    required String requestId,
    required String sourceId,
    required int deletedAtMs,
  }) {}

  @override
  void sendMessage({
    required String requestId,
    required String text,
    String? conversationId,
    String? memoryContext,
    MessageOrigin? origin,
  }) {}

  @override
  void configureAssistant({
    required String requestId,
    required AssistantProvider provider,
    required String model,
    required String credential,
    String? endpoint,
  }) {}

  @override
  void configureTrustedAssistant({
    required String requestId,
    required String managedWorkerOrigin,
  }) {}

  @override
  void clearAssistant(String requestId) {}

  @override
  void decideApproval({
    required String requestId,
    required String proposalId,
    required ApprovalDecision decision,
    ComputerUseAuthorityReceipt? authorityReceipt,
  }) {}

  @override
  void startTranscription({
    required String requestId,
    required String audioStreamId,
    required String deviceId,
    required TranscriptionAuth auth,
    required String language,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
  }) {
    events0.add(
      NativeEventTranscriptionStatus(
        value: TranscriptionStatus(
          requestId: requestId,
          audioStreamId: audioStreamId,
          state: TranscriptionState.started,
          sttEpoch: 0,
        ),
      ),
    );
  }

  @override
  void stopTranscription({
    required String requestId,
    required String audioStreamId,
  }) {
    events0.add(
      NativeEventTranscriptionStopAcknowledged(
        value: TranscriptionStopAcknowledgement(
          requestId: requestId,
          audioStreamId: audioStreamId,
          accepted: true,
        ),
      ),
    );
  }

  @override
  void cancel(String requestId) {}

  @override
  void sendAudio({
    required String requestId,
    required int sequence,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
    required bool endOfStream,
    required Uint8List bytes,
  }) {}

  @override
  void dispose() {}
}
