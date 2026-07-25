import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/rewind/rewind_client.dart';
import 'package:omi/features/rewind/rewind_platform.dart';
import 'package:omi/features/rewind/rewind_settings_tile.dart';
import 'package:omi/native/native_hub.dart';

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

/// Stands in for the hub's Rewind engine: it holds the two switches the tile
/// drives and restates them, which is all the widget reads. Everything the
/// engine actually decides is tested in Rust.
final class _FakeEngine {
  bool enabled = false;
  bool paused = false;

  Future<RewindPayload?> call(RewindRequest request) async {
    switch (request) {
      case RewindRequestSetEnabled(:final enabled):
        this.enabled = enabled;
        paused = false;
      case RewindRequestSetPaused(:final paused):
        this.paused = paused;
      default:
        break;
    }
    return RewindPayloadStatus(value: _status());
  }

  RewindStatus _status() => RewindStatus(
    enabled: enabled,
    paused: paused,
    recording: enabled && !paused,
    retentionMaxAgeDays: 14,
    retentionMaxBytes: Uint64.fromBigInt(BigInt.from(4 * 1024 * 1024 * 1024)),
    retentionOptions: [
      RewindRetentionOption(
        maxAgeDays: 14,
        maxBytes: Uint64.fromBigInt(BigInt.from(4 * 1024 * 1024 * 1024)),
        label: '14 days · 4 GB',
      ),
    ],
    deniedBundleIds: const ['com.1password.1password'],
    skipPrivateBrowsing: true,
    recordWindowTitles: true,
    readOnScreenText: true,
    capturedThisSession: Uint64.fromBigInt(BigInt.zero),
    frameCount: Uint64.fromBigInt(BigInt.zero),
    totalBytes: Uint64.fromBigInt(BigInt.zero),
    permitted: false,
    locked: false,
  );
}

void main() {
  late _SilentPlatform platform;
  late RewindClient client;

  setUp(() async {
    platform = _SilentPlatform();
    final engine = _FakeEngine();
    client = RewindClient(
      transport: engine.call,
      platform: platform,
      tickInterval: const Duration(days: 1),
      captures: false,
    );
    await client.refreshStatus();
  });

  tearDown(() {
    client.dispose();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RewindSettingsTile(client: client),
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
    expect(client.status?.enabled, isTrue);
    expect(platform.recording, isTrue);
    expect(find.byKey(const Key('rewind_pause')), findsOneWidget);
    expect(find.byKey(const Key('rewind_private_browsing')), findsOneWidget);
    expect(find.byKey(const Key('rewind_ocr')), findsOneWidget);
    expect(find.byKey(const Key('rewind_retention')), findsOneWidget);

    await tester.tap(find.byKey(const Key('rewind_pause')));
    await tester.pumpAndSettle();
    expect(client.status?.paused, isTrue);
    expect(platform.paused, isTrue);
  });
}
