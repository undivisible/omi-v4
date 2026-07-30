import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/rewind/rewind_client.dart';
import 'package:omi/features/rewind/rewind_platform.dart';
import 'package:omi/native/native_hub.dart';

/// The capture surface, counting the two calls the frame-economy invariant is
/// about. `encodeHeldFrame` turning full frames into bytes is the expensive
/// half; `discardHeldFrame` is what must happen instead whenever the engine
/// says no.
final class _CountingPlatform implements RewindCapturePlatform {
  int previewCalls = 0;
  int encodeCalls = 0;
  int discardCalls = 0;
  bool? lastRecognizeText;
  Uint8List? nextPreview = Uint8List.fromList(List<int>.filled(72, 3));
  List<RewindDisplay> availableDisplays = const [
    RewindDisplay(
      id: '1',
      name: 'Primary',
      x: 0,
      y: 0,
      width: 1920,
      height: 1080,
      scale: 2,
      primary: true,
    ),
  ];

  @override
  Future<RewindSystemState> readState() async => const RewindSystemState(
    context: RewindWindowContext(
      bundleId: 'com.apple.Terminal',
      appName: 'Terminal',
      windowTitle: 'zsh',
    ),
    idleFor: Duration.zero,
    locked: false,
    permitted: true,
  );

  @override
  Future<List<RewindDisplay>> displays() async => availableDisplays;

  @override
  Future<Uint8List?> preview(RewindDisplay display) async {
    previewCalls++;
    return nextPreview;
  }

  @override
  Future<RewindEncodedFrame?> encodeHeldFrame({
    bool recognizeText = true,
  }) async {
    encodeCalls++;
    lastRecognizeText = recognizeText;
    return RewindEncodedFrame(
      jpeg: Uint8List.fromList(List<int>.filled(32, 7)),
      ocrText: recognizeText ? 'flutter analyze' : null,
    );
  }

  @override
  Future<void> discardHeldFrame() async => discardCalls++;

  @override
  Future<void> setIndicator({
    required bool recording,
    required bool paused,
  }) async {}

  @override
  void setIndicatorHandler(void Function(String action)? handler) {}
}

/// A scripted engine: it answers each exchange with the directive the test
/// wants, and records what the client actually sent.
final class _ScriptedEngine {
  _ScriptedEngine(this._directives);

  final List<RewindDirective?> _directives;
  final sent = <RewindRequest>[];
  var _index = 0;

  Future<RewindPayload?> call(RewindRequest request) async {
    sent.add(request);
    if (request is RewindRequestStatus || request is RewindRequestListFrames) {
      return null;
    }
    if (_index >= _directives.length) return null;
    final directive = _directives[_index++];
    if (directive == null) return null;
    return RewindPayloadDirective(
      stepId: Uint64.fromBigInt(BigInt.one),
      directive: directive,
    );
  }
}

RewindClient _client(_CountingPlatform platform, _ScriptedEngine engine) =>
    RewindClient(
      transport: engine.call,
      platform: platform,
      tickInterval: const Duration(days: 1),
    );

void main() {
  test('a stage-one refusal never reads a pixel', () async {
    final platform = _CountingPlatform();
    final engine = _ScriptedEngine([
      const RewindDirectiveIdle(reason: RewindSkipReason.deniedApp),
    ]);
    final client = _client(platform, engine);
    addTearDown(client.dispose);

    await client.pump();

    expect(platform.previewCalls, 0);
    expect(platform.encodeCalls, 0);
  });

  test(
    'a frame the similarity gate rejects is dropped, never encoded',
    () async {
      final platform = _CountingPlatform();
      final engine = _ScriptedEngine([
        const RewindDirectivePreview(),
        const RewindDirectiveDiscard(reason: RewindSkipReason.unchanged),
      ]);
      final client = _client(platform, engine);
      addTearDown(client.dispose);

      await client.pump();

      expect(platform.previewCalls, 1);
      // The whole point: the held frame never became bytes.
      expect(platform.encodeCalls, 0);
      expect(platform.discardCalls, 1);
    },
  );

  test('a kept frame is encoded exactly once, after the gate', () async {
    final platform = _CountingPlatform();
    final engine = _ScriptedEngine([
      const RewindDirectivePreview(),
      const RewindDirectiveEncode(recognizeText: true),
      const RewindDirectiveStored(),
    ]);
    final client = _client(platform, engine);
    addTearDown(client.dispose);

    await client.pump();

    expect(platform.encodeCalls, 1);
    expect(platform.lastRecognizeText, isTrue);
    // Encoding consumes the held frame; discarding it again would be a
    // double-free of the native side's only slot.
    expect(platform.discardCalls, 0);
    final encoded = engine.sent.whereType<RewindRequestFrameEncoded>().single;
    expect(encoded.jpeg, hasLength(32));
    expect(encoded.ocrText, 'flutter analyze');
  });

  test('every active display gets its own capture handshake', () async {
    final platform = _CountingPlatform()
      ..availableDisplays = const [
        RewindDisplay(
          id: '1',
          name: 'Primary',
          x: 0,
          y: 0,
          width: 1920,
          height: 1080,
          scale: 2,
          primary: true,
        ),
        RewindDisplay(
          id: '2',
          name: 'External',
          x: 1920,
          y: 0,
          width: 2560,
          height: 1440,
          scale: 1,
          primary: false,
        ),
      ];
    final engine = _ScriptedEngine([
      const RewindDirectivePreview(),
      const RewindDirectiveEncode(recognizeText: false),
      const RewindDirectiveStored(),
      const RewindDirectivePreview(),
      const RewindDirectiveEncode(recognizeText: false),
      const RewindDirectiveStored(),
    ]);
    final client = _client(platform, engine);
    addTearDown(client.dispose);

    await client.pump();

    expect(platform.previewCalls, 2);
    expect(platform.encodeCalls, 2);
    expect(
      engine.sent.whereType<RewindRequestTick>().map((tick) => tick.display.id),
      ['1', '2'],
    );
  });

  test('the engine decides whether text is read off the frame', () async {
    final platform = _CountingPlatform();
    final engine = _ScriptedEngine([
      const RewindDirectivePreview(),
      const RewindDirectiveEncode(recognizeText: false),
      const RewindDirectiveStored(),
    ]);
    final client = _client(platform, engine);
    addTearDown(client.dispose);

    await client.pump();

    expect(platform.lastRecognizeText, isFalse);
    expect(
      engine.sent.whereType<RewindRequestFrameEncoded>().single.ocrText,
      isNull,
    );
  });

  test('an abandoned handshake still drops the held frame', () async {
    final platform = _CountingPlatform();
    // The engine answers the tick and then goes silent, which is what a wedged
    // bridge looks like from here.
    final engine = _ScriptedEngine([const RewindDirectivePreview(), null]);
    final client = _client(platform, engine);
    addTearDown(client.dispose);

    await client.pump();

    expect(platform.previewCalls, 1);
    expect(platform.encodeCalls, 0);
    expect(platform.discardCalls, 1);
  });

  test('a failed capture reports an empty preview and holds nothing', () async {
    final platform = _CountingPlatform()..nextPreview = null;
    final engine = _ScriptedEngine([
      const RewindDirectivePreview(),
      const RewindDirectiveDiscard(reason: RewindSkipReason.noPermission),
    ]);
    final client = _client(platform, engine);
    addTearDown(client.dispose);

    await client.pump();

    expect(
      engine.sent.whereType<RewindRequestPreviewTaken>().single.luma,
      isEmpty,
    );
    expect(platform.encodeCalls, 0);
    // Nothing was ever held, so nothing needs dropping.
    expect(platform.discardCalls, 0);
  });

  test('a tick carries the window context without any pixels', () async {
    final platform = _CountingPlatform();
    final engine = _ScriptedEngine([
      const RewindDirectiveIdle(reason: RewindSkipReason.heartbeat),
    ]);
    final client = _client(platform, engine);
    addTearDown(client.dispose);

    await client.pump();

    final tick = engine.sent.whereType<RewindRequestTick>().single;
    expect(tick.context.bundleId, 'com.apple.Terminal');
    expect(tick.context.windowTitle, 'zsh');
    expect(tick.permitted, isTrue);
    expect(tick.locked, isFalse);
  });

  test('a second pump is dropped while one is still in flight', () async {
    final platform = _CountingPlatform();
    final engine = _ScriptedEngine([
      const RewindDirectivePreview(),
      const RewindDirectiveEncode(recognizeText: true),
      const RewindDirectiveStored(),
      const RewindDirectivePreview(),
    ]);
    final client = _client(platform, engine);
    addTearDown(client.dispose);

    final first = client.pump();
    await client.pump();
    await first;

    expect(platform.previewCalls, 1);
    expect(platform.encodeCalls, 1);
  });
}
