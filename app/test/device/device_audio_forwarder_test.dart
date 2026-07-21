import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/device.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  test(
    'mobile audio is sequenced and ended with the negotiated format',
    () async {
      final adapter = _AudioAdapter();
      final hub = _RecordingHub();
      final forwarder = DeviceAudioForwarder(
        relay: DeviceRelayService(
          role: DeviceRelayRole.mobileOwner,
          adapter: adapter,
        ),
        hub: hub,
      );
      const device = RelayDevice(
        id: 'omi-1',
        name: 'Omi',
        audioCodec: DeviceAudioCodec.opusFs320,
      );

      await forwarder.start(device);
      adapter.audio.add([1, 0, 0, 10, 11]);
      adapter.audio.add([
        1,
        0,
        1,
        ...List.filled(DeviceAudioForwarder.maxFrameBytes + 1, 9),
      ]);
      adapter.audio.add([1, 0, 1, 12]);
      await forwarder.stop();

      expect(hub.audio.map((chunk) => chunk.sequence), [0, 1, 2]);
      expect(hub.audio.last.endOfStream, isTrue);
      expect(hub.audio.last.bytes, isEmpty);
      expect(
        hub.audio.every((chunk) => chunk.encoding == AudioEncoding.opus),
        isTrue,
      );
      await adapter.close();
    },
  );

  test('observer and unavailable native modes do no audio work', () async {
    final adapter = _AudioAdapter();
    final hub = _RecordingHub(available: false);
    final forwarder = DeviceAudioForwarder(
      relay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: adapter,
      ),
      hub: hub,
    );

    await forwarder.start(
      const RelayDevice(
        id: 'omi-1',
        name: 'Omi',
        audioCodec: DeviceAudioCodec.opus,
      ),
    );
    adapter.audio.add([1, 0, 0, 10]);

    expect(forwarder.active, isFalse);
    expect(hub.audio, isEmpty);
    await adapter.close();
  });

  test('pcm8 passes through at the upstream sample rate', () async {
    final adapter = _AudioAdapter();
    final hub = _RecordingHub();
    final forwarder = DeviceAudioForwarder(
      relay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: adapter,
      ),
      hub: hub,
    );

    await forwarder.start(
      const RelayDevice(
        id: 'omi-pcm8',
        name: 'Omi',
        audioCodec: DeviceAudioCodec.pcm8,
      ),
    );
    adapter.audio.add([1, 0, 0, 128]);
    await forwarder.stop();

    expect(hub.audio.first.encoding, AudioEncoding.pcmU8);
    expect(hub.audio.map((item) => item.sequence), [0, 1]);
    await adapter.close();
  });

  test('bounded forwarding drains a saturated producer in order', () async {
    final adapter = _AudioAdapter();
    final hub = _RecordingHub();
    final forwarder = DeviceAudioForwarder(
      relay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: adapter,
      ),
      hub: hub,
    );
    await forwarder.start(
      const RelayDevice(
        id: 'omi-burst',
        name: 'Omi',
        audioCodec: DeviceAudioCodec.opus,
      ),
    );

    for (var index = 0; index < 40; index += 1) {
      adapter.audio.add([1, 0, index, index]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await forwarder.stop();

    expect(hub.audio.map((item) => item.sequence), List.generate(41, (i) => i));
    expect(hub.audio.last.endOfStream, isTrue);
    await adapter.close();
  });

  test('send failure still attempts one eos and allows restart', () async {
    final adapter = _AudioAdapter();
    final hub = _RecordingHub(failFirstData: true);
    final forwarder = DeviceAudioForwarder(
      relay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: adapter,
      ),
      hub: hub,
    );
    const device = RelayDevice(
      id: 'omi-restart',
      name: 'Omi',
      audioCodec: DeviceAudioCodec.opus,
    );

    await forwarder.start(device);
    adapter.audio.add([1, 0, 0, 1]);
    await Future<void>.delayed(Duration.zero);
    await forwarder.stop();
    expect(hub.audio.where((item) => item.endOfStream), hasLength(1));
    expect(forwarder.lastError, isA<StateError>());

    await forwarder.start(device);
    adapter.audio.add([1, 0, 0, 2]);
    await forwarder.stop();
    final requestIds = hub.audio.map((item) => item.requestId).toSet();
    expect(requestIds, hasLength(2));
    expect(hub.audio.where((item) => item.endOfStream), hasLength(2));
    await adapter.close();
  });

  test('remote disconnect emits exactly one eos', () async {
    final adapter = _AudioAdapter();
    final hub = _RecordingHub();
    final forwarder = DeviceAudioForwarder(
      relay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: adapter,
      ),
      hub: hub,
    );
    await forwarder.start(
      const RelayDevice(
        id: 'omi-disconnect',
        name: 'Omi',
        audioCodec: DeviceAudioCodec.opus,
      ),
    );
    adapter.audio.add([1, 0, 0, 1]);
    adapter.connections.add(false);
    await Future<void>.delayed(Duration.zero);
    await forwarder.stop();

    expect(hub.audio.where((item) => item.endOfStream), hasLength(1));
    expect(forwarder.active, isFalse);
    await adapter.close();
  });

  test('source error and completion each emit exactly one eos', () async {
    for (final fail in [true, false]) {
      final adapter = _AudioAdapter();
      final hub = _RecordingHub();
      final forwarder = DeviceAudioForwarder(
        relay: DeviceRelayService(
          role: DeviceRelayRole.mobileOwner,
          adapter: adapter,
        ),
        hub: hub,
      );
      await forwarder.start(
        RelayDevice(
          id: fail ? 'omi-error' : 'omi-done',
          name: 'Omi',
          audioCodec: DeviceAudioCodec.opus,
        ),
      );
      if (fail) {
        adapter.audio.addError(StateError('BLE stream failed'));
      } else {
        await adapter.audio.close();
      }
      await Future<void>.delayed(Duration.zero);
      await forwarder.stop();

      expect(hub.audio.where((item) => item.endOfStream), hasLength(1));
      expect(forwarder.active, isFalse);
      await adapter.close();
    }
  });
}

final class _SentAudio {
  const _SentAudio({
    required this.sequence,
    required this.requestId,
    required this.encoding,
    required this.endOfStream,
    required this.bytes,
  });

  final int sequence;
  final String requestId;
  final AudioEncoding encoding;
  final bool endOfStream;
  final Uint8List bytes;
}

final class _RecordingHub implements NativeHub {
  _RecordingHub({this.available = true, this.failFirstData = false});

  @override
  final bool available;
  final bool failFirstData;
  final audio = <_SentAudio>[];
  bool _failed = false;

  @override
  Stream<NativeEvent> get events => const Stream.empty();

  @override
  void sendAudio({
    required String requestId,
    required int sequence,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
    required bool endOfStream,
    required Uint8List bytes,
  }) {
    if (failFirstData && !endOfStream && !_failed) {
      _failed = true;
      throw StateError('native send failed');
    }
    audio.add(
      _SentAudio(
        requestId: requestId,
        sequence: sequence,
        encoding: encoding,
        endOfStream: endOfStream,
        bytes: bytes,
      ),
    );
  }

  @override
  Future<void> initialize() async {}

  @override
  void cancel(String requestId) {}

  @override
  void capture({
    required String requestId,
    required String ingestionKey,
    required CaptureSource source,
    required int occurredAtMs,
    String? text,
    String? application,
    String? windowTitle,
  }) {}

  @override
  void configureMemory({
    required String requestId,
    required String databasePath,
    required String tenantId,
    required String personId,
  }) {}

  @override
  void dispose() {}

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
  }) {}

  @override
  void sendMessage({
    required String requestId,
    required String text,
    String? conversationId,
  }) {}

  @override
  void decideApproval({
    required String requestId,
    required String proposalId,
    required ApprovalDecision decision,
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
  void clearAssistant(String requestId) {}

  @override
  void configureTrustedAssistant({
    required String requestId,
    required String managedWorkerOrigin,
  }) {}
}

final class _AudioAdapter implements DeviceRelayAdapter {
  final audio = StreamController<List<int>>.broadcast(sync: true);
  final connections = StreamController<bool>.broadcast(sync: true);

  Future<void> close() async {
    await audio.close();
    await connections.close();
  }

  @override
  DeviceRelayCapabilities get capabilities => const DeviceRelayCapabilities(
    pairing: DeviceCapabilityState.available,
    metadata: DeviceCapabilityState.available,
    audioStreaming: DeviceCapabilityState.available,
  );

  @override
  Stream<List<int>> audioPackets(String deviceId) => audio.stream;

  @override
  Stream<bool> connectionState(String deviceId) => connections.stream;

  @override
  Future<RelayDevice> connect(String deviceId) => throw UnimplementedError();

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<RelayDevice>> scan() => throw UnimplementedError();

  @override
  Stream<DeviceRelaySnapshot> get snapshots => const Stream.empty();
}
