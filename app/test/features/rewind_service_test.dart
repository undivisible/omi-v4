import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/rewind/rewind_dhash.dart';
import 'package:omi/features/rewind/rewind_models.dart';
import 'package:omi/features/rewind/rewind_platform.dart';
import 'package:omi/features/rewind/rewind_privacy.dart';
import 'package:omi/features/rewind/rewind_service.dart';
import 'package:omi/features/rewind/rewind_settings_store.dart';
import 'package:omi/features/rewind/rewind_store.dart';

final class _FakePlatform implements RewindCapturePlatform {
  RewindSystemState state = const RewindSystemState(
    context: RewindWindowContext(
      bundleId: 'com.apple.Terminal',
      appName: 'Terminal',
      windowTitle: 'zsh',
    ),
    idleFor: Duration.zero,
    locked: false,
    permitted: true,
  );

  Uint8List? nextPreview = Uint8List.fromList([
    for (var index = 0; index < kRewindPreviewLength; index++) index * 3,
  ]);

  int encodeCalls = 0;
  int discardCalls = 0;
  bool indicatorRecording = false;
  bool indicatorPaused = false;
  String? ocrText = 'flutter analyze';
  bool lastRecognizeText = true;

  @override
  Future<RewindSystemState> readState() async => state;

  @override
  Future<Uint8List?> preview() async => nextPreview;

  @override
  Future<RewindEncodedFrame?> encodeHeldFrame({
    bool recognizeText = true,
  }) async {
    encodeCalls++;
    lastRecognizeText = recognizeText;
    return RewindEncodedFrame(
      jpeg: Uint8List.fromList(List<int>.filled(32, 7)),
      ocrText: recognizeText ? ocrText : null,
    );
  }

  @override
  Future<void> discardHeldFrame() async => discardCalls++;

  @override
  Future<void> setIndicator({
    required bool recording,
    required bool paused,
  }) async {
    indicatorRecording = recording;
    indicatorPaused = paused;
  }

  @override
  void setIndicatorHandler(void Function(String action)? handler) {}
}

void main() {
  late Directory root;
  late _FakePlatform platform;
  late RewindStore store;
  late VolatileRewindSettingsStore settings;
  late DateTime now;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rewind_service_test');
    platform = _FakePlatform();
    store = RewindStore(root);
    settings = VolatileRewindSettingsStore();
    now = DateTime(2026, 7, 23, 9);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<RewindService> build() async {
    final service = RewindService(
      platform: platform,
      store: store,
      settingsStore: settings,
      tickInterval: const Duration(days: 1),
      clock: () => now,
    );
    await service.initialize();
    return service;
  }

  test('captures nothing until the user turns it on', () async {
    final service = await build();
    addTearDown(service.dispose);
    await service.pump();
    expect(service.frames, isEmpty);
    expect(service.lastSkipReason, RewindSkipReason.paused);
    expect(platform.indicatorRecording, isFalse);
  });

  test('stores a frame with its on-device text once enabled', () async {
    final service = await build();
    addTearDown(service.dispose);
    await service.setEnabled(true);
    await service.pump();
    expect(service.frames, hasLength(1));
    expect(service.frames.single.ocrText, 'flutter analyze');
    expect(service.frames.single.windowTitle, 'zsh');
    expect(platform.indicatorRecording, isTrue);
  });

  test('never encodes a frame the similarity gate rejects', () async {
    final service = await build();
    addTearDown(service.dispose);
    await service.setEnabled(true);
    await service.pump();
    expect(platform.encodeCalls, 1);

    now = now.add(const Duration(minutes: 1));
    await service.pump();
    expect(service.lastSkipReason, RewindSkipReason.unchanged);
    // The held frame was dropped without ever becoming bytes.
    expect(platform.encodeCalls, 1);
    expect(platform.discardCalls, greaterThan(0));
    expect(service.frames, hasLength(1));
  });

  test('pausing stops capture and says so', () async {
    final service = await build();
    addTearDown(service.dispose);
    await service.setEnabled(true);
    await service.setPaused(true);
    now = now.add(const Duration(minutes: 1));
    await service.pump();
    expect(service.frames, isEmpty);
    expect(service.lastSkipReason, RewindSkipReason.paused);
    expect(platform.indicatorPaused, isTrue);
    expect(service.recording, isFalse);
  });

  test('an excluded app is never photographed', () async {
    final service = await build();
    addTearDown(service.dispose);
    await service.setEnabled(true);
    await service.denyBundleId('com.apple.Terminal');
    await service.pump();
    expect(service.frames, isEmpty);
    expect(service.lastSkipReason, RewindSkipReason.deniedApp);
    expect(platform.encodeCalls, 0);
  });

  test('a locked screen halts capture', () async {
    final service = await build();
    addTearDown(service.dispose);
    await service.setEnabled(true);
    platform.state = RewindSystemState(
      context: platform.state.context,
      idleFor: Duration.zero,
      locked: true,
      permitted: true,
    );
    await service.pump();
    expect(service.frames, isEmpty);
    expect(service.lastSkipReason, RewindSkipReason.screenLocked);
    expect(service.recording, isFalse);
  });

  test('turning off on-device text recognition stops transcribing', () async {
    final service = await build();
    addTearDown(service.dispose);
    await service.setEnabled(true);
    await service.setPrivacy(
      const RewindPrivacySettings(readOnScreenText: false),
    );
    await service.pump();
    expect(platform.lastRecognizeText, isFalse);
    expect(service.frames.single.ocrText, isNull);
  });

  test('window titles can be kept out of the store', () async {
    final service = await build();
    addTearDown(service.dispose);
    await service.setEnabled(true);
    await service.setPrivacy(
      const RewindPrivacySettings(recordWindowTitles: false),
    );
    await service.pump();
    expect(service.frames.single.windowTitle, isNull);
    expect(service.frames.single.appName, 'Terminal');
  });

  test('deleting everything really removes the frames', () async {
    final service = await build();
    addTearDown(service.dispose);
    await service.setEnabled(true);
    await service.pump();
    final file = store.fileFor(service.frames.single);
    expect(await file.exists(), isTrue);
    await service.deleteAll();
    expect(service.frames, isEmpty);
    expect(await file.exists(), isFalse);
  });

  test('retention is applied the moment it is tightened', () async {
    final service = await build();
    addTearDown(service.dispose);
    await service.setEnabled(true);
    await service.pump();
    now = now.add(const Duration(days: 3));
    await service.setRetention(
      const RewindRetention(maxAge: Duration(days: 1), maxBytes: 1 << 30),
    );
    expect(service.frames, isEmpty);
  });
}
