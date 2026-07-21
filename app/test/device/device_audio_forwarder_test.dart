import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/device.dart';
import 'package:omi/native/generated/signals/signals.dart' show NativeError;
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
      adapter.audio.add([2, 0, 0, 12]);
      await adapter.audio.close();
      await _waitForInactive(forwarder);
      await forwarder.stop();

      expect(hub.audio.last.endOfStream, isTrue);
      expect(hub.audio.map((chunk) => chunk.sequence), [0, 1, 2]);
      expect(hub.audio.last.bytes, isEmpty);
      expect(
        hub.audio.every((chunk) => chunk.encoding == AudioEncoding.opus),
        isTrue,
      );
      expect(hub.starts, hasLength(1));
      expect(hub.stops, isEmpty);
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

  test('pcm8 stays unsigned until the native provider boundary', () async {
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
    adapter.audio.add([1, 0, 0, 0, 128, 255]);
    await adapter.audio.close();
    await _waitForInactive(forwarder);
    await forwarder.stop();

    expect(hub.audio.first.encoding, AudioEncoding.pcmU8);
    expect(hub.audio.first.bytes, [0, 128, 255]);
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
      adapter.audio.add([index & 0xff, index >> 8, 0, index]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await adapter.audio.close();
    await _waitForInactive(forwarder);
    await forwarder.stop();

    expect(hub.audio.map((item) => item.sequence), List.generate(41, (i) => i));
    expect(hub.audio.last.endOfStream, isTrue);
    await adapter.close();
  });

  test(
    'packet loss or reorder terminates with a typed gap and one stop',
    () async {
      for (final (
            receivedPacketId,
            receivedPacketIndex,
            reason,
            previousPacketId,
          )
          in [
            (12, 0, DeviceAudioGapReason.packetDiscontinuity, 10),
            (10, 0, DeviceAudioGapReason.packetDiscontinuity, 10),
            (11, 2, DeviceAudioGapReason.packetDiscontinuity, 10),
          ]) {
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
            id: 'omi-gap',
            name: 'Omi',
            audioCodec: DeviceAudioCodec.opus,
          ),
        );

        adapter.audio.add([10, 0, 0, 1]);
        adapter.audio.add([receivedPacketId, 0, receivedPacketIndex, 2]);
        await Future<void>.delayed(Duration.zero);
        await forwarder.stop();

        expect(
          hub.audio.where((item) => !item.endOfStream).length,
          lessThanOrEqualTo(1),
        );
        expect(hub.audio.where((item) => item.endOfStream), isEmpty);
        expect(hub.stops, hasLength(1));
        expect(
          forwarder.lastGap,
          isA<DeviceAudioGap>()
              .having((gap) => gap.reason, 'reason', reason)
              .having(
                (gap) => gap.previousPacketId,
                'previousPacketId',
                previousPacketId,
              )
              .having((gap) => gap.packetId, 'packetId', receivedPacketId),
        );
        await adapter.close();
      }
    },
  );

  test('packet continuity accepts the 16-bit packet id rollover', () async {
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
        id: 'omi-rollover',
        name: 'Omi',
        audioCodec: DeviceAudioCodec.opus,
      ),
    );

    adapter.audio.add([255, 255, 0, 1]);
    adapter.audio.add([0, 0, 0, 2]);
    await adapter.audio.close();
    await _waitForInactive(forwarder);
    await forwarder.stop();

    expect(hub.audio.map((item) => item.sequence), [0, 1, 2]);
    expect(forwarder.lastGap, isNull);
    await adapter.close();
  });

  test(
    'invalid first fragment and oversized frames surface typed gaps',
    () async {
      final cases = <(List<int>, DeviceAudioGapReason)>[
        ([1, 0, 1, 1], DeviceAudioGapReason.invalidStart),
        (
          [1, 0, 0, ...List.filled(DeviceAudioForwarder.maxFrameBytes + 1, 9)],
          DeviceAudioGapReason.frameTooLarge,
        ),
      ];
      for (final (packet, reason) in cases) {
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
            id: 'omi-invalid',
            name: 'Omi',
            audioCodec: DeviceAudioCodec.opus,
          ),
        );

        adapter.audio.add(packet);
        if (packet[2] == 0) adapter.audio.add([2, 0, 0, 1]);
        await Future<void>.delayed(Duration.zero);
        await forwarder.stop();

        expect(hub.audio.where((item) => !item.endOfStream), isEmpty);
        expect(hub.audio.where((item) => item.endOfStream), isEmpty);
        expect(hub.stops, hasLength(1));
        expect(forwarder.lastGap?.reason, reason);
        await adapter.close();
      }
    },
  );

  test('send failure stops once and allows restart', () async {
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
    adapter.audio.add([2, 0, 0, 2]);
    await Future<void>.delayed(Duration.zero);
    await forwarder.stop();
    expect(hub.audio.where((item) => item.endOfStream), isEmpty);
    expect(hub.stops, hasLength(1));
    expect(forwarder.lastError, isA<StateError>());

    await forwarder.start(device);
    adapter.audio.add([1, 0, 0, 2]);
    await forwarder.stop();
    expect(hub.starts, hasLength(2));
    expect(hub.stops, hasLength(2));
    expect(hub.audio.where((item) => item.endOfStream), isEmpty);
    await adapter.close();
  });

  test('remote disconnect stops exactly once', () async {
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

    expect(hub.audio.where((item) => item.endOfStream), isEmpty);
    expect(hub.stops, hasLength(1));
    expect(forwarder.active, isFalse);
    await adapter.close();
  });

  test('source error stops while normal completion emits one eos', () async {
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
        await _waitForInactive(forwarder);
      }
      await Future<void>.delayed(Duration.zero);
      await forwarder.stop();

      expect(
        hub.audio.where((item) => item.endOfStream),
        fail ? isEmpty : hasLength(1),
      );
      expect(hub.stops, fail ? hasLength(1) : isEmpty);
      expect(forwarder.active, isFalse);
      await adapter.close();
    }
  });

  test(
    'waits for the matching started acknowledgement before forwarding audio',
    () async {
      final adapter = _AudioAdapter();
      final hub = _RecordingHub(autoStartAck: false);
      final forwarder = DeviceAudioForwarder(
        relay: DeviceRelayService(
          role: DeviceRelayRole.mobileOwner,
          adapter: adapter,
        ),
        hub: hub,
        auth: TranscriptionAuthManaged(
          endpoint:
              'wss://api.example.test/v1/stt/sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/stream',
          firebaseToken: 'token',
        ),
        language: 'es',
      );
      const device = RelayDevice(
        id: 'omi-ack',
        name: 'Omi',
        audioCodec: DeviceAudioCodec.opus,
      );

      var started = false;
      final start = forwarder.start(device).then((_) => started = true);
      await Future<void>.delayed(Duration.zero);
      adapter.audio.add([1, 0, 0, 1]);
      hub.ackStart(requestId: 'unrelated');
      await Future<void>.delayed(Duration.zero);
      expect(started, isFalse);
      expect(hub.audio, isEmpty);

      hub.ackStart();
      await start;
      adapter.audio.add([1, 0, 0, 2]);
      await adapter.audio.close();
      await _waitForInactive(forwarder);

      expect(hub.audio.where((item) => !item.endOfStream), hasLength(1));
      expect(hub.audio.where((item) => item.endOfStream), hasLength(1));
      expect(hub.starts.single.auth, isA<TranscriptionAuthManaged>());
      expect(hub.starts.single.language, 'es');
      expect(hub.stops, isEmpty);
      await adapter.close();
    },
  );

  test(
    'start acknowledgement timeout stops exactly once without forwarding audio',
    () async {
      final adapter = _AudioAdapter();
      final hub = _RecordingHub(autoStartAck: false);
      final forwarder = DeviceAudioForwarder(
        relay: DeviceRelayService(
          role: DeviceRelayRole.mobileOwner,
          adapter: adapter,
        ),
        hub: hub,
        startTimeout: const Duration(milliseconds: 5),
      );

      await expectLater(
        forwarder.start(
          const RelayDevice(
            id: 'omi-timeout',
            name: 'Omi',
            audioCodec: DeviceAudioCodec.opus,
          ),
        ),
        throwsA(isA<DeviceTranscriptionStartTimeout>()),
      );

      expect(hub.audio, isEmpty);
      expect(hub.stops, hasLength(1));
      expect(forwarder.active, isFalse);
      await adapter.close();
    },
  );

  test(
    'cancellation while awaiting start acknowledgement stops exactly once',
    () async {
      final adapter = _AudioAdapter();
      final hub = _RecordingHub(autoStartAck: false);
      final forwarder = DeviceAudioForwarder(
        relay: DeviceRelayService(
          role: DeviceRelayRole.mobileOwner,
          adapter: adapter,
        ),
        hub: hub,
      );

      final start = expectLater(
        forwarder.start(
          const RelayDevice(
            id: 'omi-cancel',
            name: 'Omi',
            audioCodec: DeviceAudioCodec.opus,
          ),
        ),
        throwsA(isA<DeviceTranscriptionStartCancelled>()),
      );
      await Future<void>.delayed(Duration.zero);
      await forwarder.stop();
      await start;

      expect(hub.audio, isEmpty);
      expect(hub.stops, hasLength(1));
      expect(forwarder.active, isFalse);
      await adapter.close();
    },
  );

  test('native start errors fail immediately and stop exactly once', () async {
    final adapter = _AudioAdapter();
    final hub = _RecordingHub(autoStartAck: false);
    final forwarder = DeviceAudioForwarder(
      relay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: adapter,
      ),
      hub: hub,
      startTimeout: const Duration(seconds: 30),
    );

    final start = expectLater(
      forwarder.start(
        const RelayDevice(
          id: 'omi-rejected',
          name: 'Omi',
          audioCodec: DeviceAudioCodec.opus,
        ),
      ),
      throwsA(isA<DeviceTranscriptionStartFailed>()),
    );
    await Future<void>.delayed(Duration.zero);
    hub.rejectStart();
    await start;

    expect(hub.stops, hasLength(1));
    expect(forwarder.active, isFalse);
    await adapter.close();
  });

  test('a concurrent start aborts the superseded native session', () async {
    final adapter = _AudioAdapter();
    final hub = _RecordingHub(autoStartAck: false);
    final forwarder = DeviceAudioForwarder(
      relay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: adapter,
      ),
      hub: hub,
    );

    final first = expectLater(
      forwarder.start(
        const RelayDevice(
          id: 'omi-first',
          name: 'Omi',
          audioCodec: DeviceAudioCodec.opus,
        ),
      ),
      throwsA(isA<DeviceTranscriptionStartCancelled>()),
    );
    await Future<void>.delayed(Duration.zero);
    final second = forwarder.start(
      const RelayDevice(
        id: 'omi-second',
        name: 'Omi',
        audioCodec: DeviceAudioCodec.opus,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    hub.ackStart();
    await Future.wait([first, second]);

    expect(hub.starts, hasLength(2));
    expect(hub.stops, hasLength(1));
    expect(hub.stops.single.$2, hub.starts.first.audioStreamId);
    await forwarder.stop();
    expect(hub.stops, hasLength(2));
    await adapter.close();
  });

  test(
    'explicit stop upgrades a racing graceful completion to abort',
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
      await forwarder.start(
        const RelayDevice(
          id: 'omi-race',
          name: 'Omi',
          audioCodec: DeviceAudioCodec.opus,
        ),
      );
      adapter.audio.add([1, 0, 0, 1]);

      final closing = adapter.audio.close();
      final stopping = forwarder.stop();
      await Future.wait([closing, stopping]);

      expect(hub.audio.where((item) => item.endOfStream), isEmpty);
      expect(hub.stops, hasLength(1));
      await adapter.close();
    },
  );

  test('failed eos delivery falls back to stop exactly once', () async {
    final adapter = _AudioAdapter();
    final hub = _RecordingHub(failEos: true);
    final forwarder = DeviceAudioForwarder(
      relay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: adapter,
      ),
      hub: hub,
    );
    await forwarder.start(
      const RelayDevice(
        id: 'omi-eos-fail',
        name: 'Omi',
        audioCodec: DeviceAudioCodec.opus,
      ),
    );
    adapter.audio.add([1, 0, 0, 1]);
    await adapter.audio.close();
    await _waitForInactive(forwarder);

    expect(hub.audio.where((item) => item.endOfStream), isEmpty);
    expect(hub.stops, hasLength(1));
    expect(forwarder.lastError, isA<StateError>());
    await forwarder.stop();
    expect(hub.stops, hasLength(1));
    await adapter.close();
  });

  test('local and remote concurrent stop before eos correlate once', () async {
    for (final auth in <TranscriptionAuth>[
      const TranscriptionAuthLocal(),
      const TranscriptionAuthManaged(
        endpoint:
            'wss://api.example.test/v1/stt/sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/stream',
        firebaseToken: 'firebase-token',
      ),
    ]) {
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
          id: 'omi-stop-before-eos',
          name: 'Omi',
          audioCodec: DeviceAudioCodec.opus,
        ),
        auth: auth,
      );
      adapter.audio.add([1, 0, 0, 1, 2]);

      await Future.wait([forwarder.stop(), forwarder.stop()]);

      expect(hub.stops, hasLength(1));
      expect(hub.stopAcknowledgements, hasLength(1));
      expect(hub.stopAcknowledgements.single.requestId, hub.stops.single.$1);
      expect(hub.lifecycleTerminals, hasLength(1));
      expect(
        hub.lifecycleTerminals.single.requestId,
        hub.starts.single.requestId,
      );
      expect(
        hub.lifecycleTerminals.single.requestId,
        isNot(hub.stopAcknowledgements.single.requestId),
      );
      expect(hub.audio.where((item) => item.endOfStream), isEmpty);
      expect(forwarder.active, isFalse);
      await adapter.close();
    }
  });
}

Future<void> _waitForInactive(DeviceAudioForwarder forwarder) async {
  for (var attempt = 0; attempt < 20 && forwarder.active; attempt += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(forwarder.active, isFalse);
}

typedef _StartedTranscription = ({
  String requestId,
  String audioStreamId,
  String deviceId,
  TranscriptionAuth auth,
  String language,
});

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
  _RecordingHub({
    this.available = true,
    this.failFirstData = false,
    this.failEos = false,
    this.autoStartAck = true,
  });

  @override
  final bool available;
  final bool failFirstData;
  final bool failEos;
  final bool autoStartAck;
  final audio = <_SentAudio>[];
  final starts = <_StartedTranscription>[];
  final stops = <(String, String)>[];
  final stopAcknowledgements = <TranscriptionStopAcknowledgement>[];
  final lifecycleTerminals = <TranscriptionStatus>[];
  final eventsController = StreamController<NativeEvent>.broadcast(sync: true);
  bool _failed = false;

  @override
  Stream<NativeEvent> get events => eventsController.stream;

  @override
  void correctMemory({
    required String requestId,
    required String claimId,
    required String text,
    required String value,
    required int occurredAtMs,
  }) {}

  @override
  void deleteMemorySource({
    required String requestId,
    required String sourceId,
    required int deletedAtMs,
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
    starts.add((
      requestId: requestId,
      audioStreamId: audioStreamId,
      deviceId: deviceId,
      auth: auth,
      language: language,
    ));
    if (autoStartAck) ackStart();
  }

  void ackStart({String? requestId, String? audioStreamId}) {
    final start = starts.last;
    eventsController.add(
      NativeEventTranscriptionStatus(
        value: TranscriptionStatus(
          requestId: requestId ?? start.requestId,
          audioStreamId: audioStreamId ?? start.audioStreamId,
          state: TranscriptionState.started,
          sttEpoch: 0,
        ),
      ),
    );
  }

  void rejectStart() {
    final start = starts.last;
    eventsController.add(
      NativeEventError(
        value: NativeError(
          requestId: start.requestId,
          code: 'transcription_start_invalid',
          message: 'start rejected',
          retryable: false,
        ),
      ),
    );
  }

  @override
  void stopTranscription({
    required String requestId,
    required String audioStreamId,
  }) {
    stops.add((requestId, audioStreamId));
    final acknowledgement = TranscriptionStopAcknowledgement(
      requestId: requestId,
      audioStreamId: audioStreamId,
      accepted: true,
    );
    stopAcknowledgements.add(acknowledgement);
    eventsController.add(
      NativeEventTranscriptionStopAcknowledged(value: acknowledgement),
    );
    final start = starts.firstWhere(
      (candidate) => candidate.audioStreamId == audioStreamId,
    );
    final terminal = TranscriptionStatus(
      requestId: start.requestId,
      audioStreamId: audioStreamId,
      state: TranscriptionState.cancelled,
      sttEpoch: 0,
    );
    lifecycleTerminals.add(terminal);
    eventsController.add(NativeEventTranscriptionStatus(value: terminal));
  }

  @override
  void approveAndExecuteComputerUse({
    required String requestId,
    required String proposalId,
  }) {}

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
    if (failEos && endOfStream) {
      throw StateError('native eos send failed');
    }
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
    TranscriptLocator? transcriptLocator,
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
    if (!audio.isClosed) await audio.close();
    if (!connections.isClosed) await connections.close();
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
