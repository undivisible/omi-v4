import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/rewind/rewind_platform.dart';
import 'package:omi/features/rewind/rewind_service.dart';
import 'package:omi/features/rewind/rewind_settings_store.dart';
import 'package:omi/features/rewind/rewind_settings_tile.dart';
import 'package:omi/features/rewind/rewind_store.dart';

final class _SilentPlatform implements RewindCapturePlatform {
  bool recording = false;
  bool paused = false;

  @override
  Future<RewindSystemState> readState() async => RewindSystemState.unavailable;

  @override
  Future<Uint8List?> preview() async => null;

  @override
  Future<RewindEncodedFrame?> encodeHeldFrame({
    bool recognizeText = true,
  }) async => null;

  @override
  Future<void> discardHeldFrame() async {}

  @override
  Future<void> setIndicator({
    required bool recording,
    required bool paused,
  }) async {
    this.recording = recording;
    this.paused = paused;
  }

  @override
  void setIndicatorHandler(void Function(String action)? handler) {}
}

void main() {
  late Directory root;
  late _SilentPlatform platform;
  late RewindService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rewind_tile_test');
    platform = _SilentPlatform();
    service = RewindService(
      platform: platform,
      store: RewindStore(root),
      settingsStore: VolatileRewindSettingsStore(),
      tickInterval: const Duration(days: 1),
      captures: false,
    );
    await service.initialize();
  });

  tearDown(() async {
    service.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RewindSettingsTile(service: service),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('recording is off until the user opts in', (tester) async {
    await pump(tester);
    final toggle = tester.widget<Switch>(
      find.byKey(const Key('rewind_enabled')),
    );
    expect(toggle.value, isFalse);
    expect(
      find.text('Off. Rewind captures nothing until you turn this on.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('rewind_pause')), findsNothing);
  });

  testWidgets('turning it on reveals the pause and the privacy controls', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('rewind_enabled')));
    await tester.pumpAndSettle();
    expect(service.settings.enabled, isTrue);
    expect(platform.recording, isTrue);
    expect(find.byKey(const Key('rewind_pause')), findsOneWidget);
    expect(find.byKey(const Key('rewind_private_browsing')), findsOneWidget);
    expect(find.byKey(const Key('rewind_ocr')), findsOneWidget);
    expect(find.byKey(const Key('rewind_retention')), findsOneWidget);

    await tester.tap(find.byKey(const Key('rewind_pause')));
    await tester.pumpAndSettle();
    expect(service.settings.paused, isTrue);
    expect(platform.paused, isTrue);
  });
}
