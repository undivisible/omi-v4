import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../native/native_hub.dart';
import 'device_audio_frame.dart';
import 'device_models.dart';
import 'device_relay.dart';

final class DeviceAudioForwarder {
  DeviceAudioForwarder({required this.relay, required this.hub});

  static const maxFrameBytes = 256 * 1024;
  static const maxPendingFrames = 8;

  final DeviceRelayService relay;
  final NativeHub hub;
  _AudioSession? _session;
  Object? lastError;

  bool get active => _session != null;

  Future<void> start(RelayDevice device) async {
    await stop();
    lastError = null;
    if (!hub.available ||
        relay.role != DeviceRelayRole.mobileOwner ||
        relay.capabilities.audioStreaming != DeviceCapabilityState.available) {
      return;
    }
    final encoding = switch (device.audioCodec) {
      DeviceAudioCodec.pcm8 => AudioEncoding.pcmU8,
      DeviceAudioCodec.pcm16 => AudioEncoding.pcmS16Le,
      DeviceAudioCodec.opus || DeviceAudioCodec.opusFs320 => AudioEncoding.opus,
      DeviceAudioCodec.unknown => null,
    };
    if (encoding == null) {
      throw StateError('The connected Omi reported an unknown audio codec.');
    }

    final session = _AudioSession(
      requestId: 'omi-${device.id}-${DateTime.now().microsecondsSinceEpoch}',
      encoding: encoding,
      sampleRateHz: device.audioCodec.sampleRate,
    );
    _session = session;
    session.audioSubscription = relay
        .audioFrames(device.id)
        .listen(
          (frame) => _accept(session, frame),
          onError: (Object error, StackTrace stackTrace) {
            lastError = error;
            unawaited(_finish(session));
          },
          onDone: () => unawaited(_finish(session)),
          cancelOnError: true,
        );
    session.connectionSubscription = relay
        .connectionState(device.id)
        .listen(
          (connected) {
            if (!connected) unawaited(_finish(session));
          },
          onError: (Object error, StackTrace stackTrace) {
            lastError = error;
            unawaited(_finish(session));
          },
        );
  }

  void _accept(_AudioSession session, DeviceAudioFrame frame) {
    if (_session != session || !session.accepting) return;
    if (frame.payload.length > maxFrameBytes) return;
    if (session.pending.length >= maxPendingFrames) return;
    session.pending.add(frame.payload);
    if (session.pending.length >= maxPendingFrames) {
      session.audioSubscription?.pause();
    }
    session.drain = session.drain.then((_) => _drain(session));
  }

  Future<void> _drain(_AudioSession session) async {
    while (_session == session && session.pending.isNotEmpty) {
      final bytes = session.pending.removeFirst();
      await Future<void>.delayed(Duration.zero);
      try {
        hub.sendAudio(
          requestId: session.requestId,
          sequence: session.sequence,
          sampleRateHz: session.sampleRateHz,
          channels: 1,
          encoding: session.encoding,
          endOfStream: false,
          bytes: bytes,
        );
        session.sequence += 1;
      } catch (error) {
        lastError = error;
        session.accepting = false;
        session.pending.clear();
        scheduleMicrotask(() => unawaited(_finish(session)));
        return;
      }
      if (session.audioSubscription?.isPaused ?? false) {
        session.audioSubscription?.resume();
      }
    }
  }

  Future<void> stop() async {
    final session = _session;
    if (session != null) await _finish(session);
  }

  Future<void> _finish(_AudioSession session) async {
    if (session.finishing) return session.finished.future;
    session.finishing = true;
    session.accepting = false;
    await session.audioSubscription?.cancel();
    await session.connectionSubscription?.cancel();
    await session.drain;
    if (!session.eosAttempted) {
      session.eosAttempted = true;
      try {
        hub.sendAudio(
          requestId: session.requestId,
          sequence: session.sequence,
          sampleRateHz: session.sampleRateHz,
          channels: 1,
          encoding: session.encoding,
          endOfStream: true,
          bytes: Uint8List(0),
        );
        session.sequence += 1;
      } catch (error) {
        lastError = error;
      }
    }
    session.pending.clear();
    if (_session == session) _session = null;
    if (!session.finished.isCompleted) session.finished.complete();
  }
}

final class _AudioSession {
  _AudioSession({
    required this.requestId,
    required this.encoding,
    required this.sampleRateHz,
  });

  final String requestId;
  final AudioEncoding encoding;
  final int sampleRateHz;
  final pending = ListQueue<Uint8List>();
  final finished = Completer<void>();
  StreamSubscription<DeviceAudioFrame>? audioSubscription;
  StreamSubscription<bool>? connectionSubscription;
  Future<void> drain = Future.value();
  int sequence = 0;
  bool accepting = true;
  bool finishing = false;
  bool eosAttempted = false;
}
