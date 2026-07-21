import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../native/generated/signals/signals.dart' show NativeError;
import '../native/native_hub.dart';
import 'device_audio_frame.dart';
import 'device_models.dart';
import 'device_relay.dart';

enum DeviceAudioGapReason {
  invalidStart,
  packetDiscontinuity,
  frameTooLarge,
  bufferCapacity,
}

final class DeviceAudioGap implements Exception {
  const DeviceAudioGap({
    required this.deviceId,
    required this.reason,
    required this.packetId,
    required this.packetIndex,
    this.previousPacketId,
    this.previousPacketIndex,
  });

  final String deviceId;
  final DeviceAudioGapReason reason;
  final int packetId;
  final int packetIndex;
  final int? previousPacketId;
  final int? previousPacketIndex;

  @override
  String toString() =>
      'DeviceAudioGap(deviceId: $deviceId, reason: ${reason.name}, '
      'previous: $previousPacketId/$previousPacketIndex, '
      'received: $packetId/$packetIndex)';
}

final class DeviceTranscriptionStartTimeout implements Exception {
  const DeviceTranscriptionStartTimeout(this.audioStreamId);

  final String audioStreamId;
}

final class DeviceTranscriptionStartCancelled implements Exception {
  const DeviceTranscriptionStartCancelled(this.audioStreamId);

  final String audioStreamId;
}

final class DeviceTranscriptionStartRejected implements Exception {
  const DeviceTranscriptionStartRejected(this.audioStreamId, this.state);

  final String audioStreamId;
  final TranscriptionState state;
}

final class DeviceTranscriptionStartFailed implements Exception {
  const DeviceTranscriptionStartFailed(this.audioStreamId, this.error);

  final String audioStreamId;
  final NativeError error;
}

final class DeviceTranscriptionStopTimeout implements Exception {
  const DeviceTranscriptionStopTimeout(this.audioStreamId);

  final String audioStreamId;
}

final class DeviceTranscriptionStopRejected implements Exception {
  const DeviceTranscriptionStopRejected(this.audioStreamId);

  final String audioStreamId;
}

final class DeviceAudioForwarder {
  DeviceAudioForwarder({
    required this.relay,
    required this.hub,
    this.auth = const TranscriptionAuthLocal(),
    this.language = 'multi',
    this.startTimeout = const Duration(seconds: 5),
    this.stopTimeout = const Duration(seconds: 5),
    this.reconnectGrace = const Duration(seconds: 20),
  });

  static const maxFrameBytes = 256 * 1024;
  static const maxPendingFrames = 8;

  final DeviceRelayService relay;
  final NativeHub hub;
  final TranscriptionAuth auth;
  final String language;
  final Duration startTimeout;
  final Duration stopTimeout;
  final Duration reconnectGrace;
  _AudioSession? _session;
  int _startGeneration = 0;
  Object? lastError;

  bool get active => _session != null;
  DeviceAudioGap? get lastGap => switch (lastError) {
    final DeviceAudioGap gap => gap,
    _ => null,
  };

  Future<void> start(RelayDevice device, {TranscriptionAuth? auth}) async {
    final generation = ++_startGeneration;
    await _stopCurrent();
    if (generation != _startGeneration) {
      throw DeviceTranscriptionStartCancelled(device.id);
    }
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
      deviceId: device.id,
      encoding: encoding,
      sampleRateHz: device.audioCodec.sampleRate,
    );
    _session = session;
    try {
      await _startTranscription(session, auth ?? this.auth);
    } catch (error) {
      lastError = error;
      await _finish(session, abort: true);
      rethrow;
    }
    if (generation != _startGeneration ||
        _session != session ||
        session.finishing) {
      await _finish(session, abort: true);
      throw DeviceTranscriptionStartCancelled(session.requestId);
    }
    session.started = true;
    session.audioSubscription = relay
        .audioFrames(device.id)
        .listen(
          (frame) => _accept(session, frame),
          onError: (Object error, StackTrace stackTrace) {
            lastError = error;
            unawaited(_finish(session, abort: true));
          },
          onDone: () => unawaited(_finish(session)),
          cancelOnError: true,
        );
    session.connectionSubscription = relay
        .connectionState(device.id)
        .listen(
          (connected) {
            if (connected) {
              session.reconnectTimer?.cancel();
              session.reconnectTimer = null;
              session.connected = true;
              session.previousPacketId = null;
              session.previousPacketIndex = null;
            } else if (session.connected && session.reconnectTimer == null) {
              session.connected = false;
              session.reconnectTimer = Timer(
                reconnectGrace,
                () => unawaited(_finish(session, abort: true)),
              );
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            lastError = error;
            unawaited(_finish(session, abort: true));
          },
        );
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> _startTranscription(
    _AudioSession session,
    TranscriptionAuth auth,
  ) async {
    final response = Completer<TranscriptionStatus>();
    final subscription = hub.events.listen(
      (event) {
        if (event case NativeEventTranscriptionStatus(:final value)
            when value.requestId == session.startRequestId &&
                value.audioStreamId == session.requestId &&
                !response.isCompleted) {
          response.complete(value);
        } else if (event case NativeEventError(:final value)
            when value.requestId == session.startRequestId &&
                !response.isCompleted) {
          response.completeError(
            DeviceTranscriptionStartFailed(session.requestId, value),
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!response.isCompleted) response.completeError(error, stackTrace);
      },
    );
    try {
      hub.startTranscription(
        requestId: session.startRequestId,
        audioStreamId: session.requestId,
        deviceId: session.deviceId,
        auth: auth,
        language: language,
        sampleRateHz: session.sampleRateHz,
        channels: 1,
        encoding: session.encoding,
      );
      final status =
          await Future.any<TranscriptionStatus>([
            response.future,
            session.startCancelled.future.then(
              (_) => throw DeviceTranscriptionStartCancelled(session.requestId),
            ),
          ]).timeout(
            startTimeout,
            onTimeout: () =>
                throw DeviceTranscriptionStartTimeout(session.requestId),
          );
      if (status.state != TranscriptionState.started) {
        throw DeviceTranscriptionStartRejected(session.requestId, status.state);
      }
    } finally {
      await subscription.cancel();
    }
  }

  void _accept(_AudioSession session, DeviceAudioFrame frame) {
    if (_session != session || !session.accepting || !session.connected) return;
    final gap = _continuityGap(session, frame);
    if (gap != null) {
      _fail(session, gap);
      return;
    }
    if (frame.payload.length > maxFrameBytes) {
      _fail(session, _gap(session, frame, DeviceAudioGapReason.frameTooLarge));
      return;
    }
    if (session.pending.length >= maxPendingFrames) {
      _fail(session, _gap(session, frame, DeviceAudioGapReason.bufferCapacity));
      return;
    }
    if (session.pending.length == maxPendingFrames - 1 &&
        !(session.audioSubscription?.isPaused ?? false)) {
      session.audioSubscription?.pause();
    }
    session.previousPacketId = frame.packetId;
    session.previousPacketIndex = frame.packetIndex;
    session.pending.add(frame.payload);
    session.drain = session.drain.then((_) => _drain(session));
  }

  DeviceAudioGap? _continuityGap(
    _AudioSession session,
    DeviceAudioFrame frame,
  ) {
    if (!frame.complete) {
      final reason = switch (frame.error) {
        DeviceAudioFrameError.discontinuity =>
          DeviceAudioGapReason.packetDiscontinuity,
        DeviceAudioFrameError.tooLarge => DeviceAudioGapReason.frameTooLarge,
        null =>
          session.previousPacketId == null
              ? DeviceAudioGapReason.invalidStart
              : DeviceAudioGapReason.packetDiscontinuity,
      };
      return _gap(session, frame, reason);
    }
    final previousPacketId = session.previousPacketId;
    final previousPacketIndex = session.previousPacketIndex;
    if (previousPacketId == null || previousPacketIndex == null) {
      return frame.packetIndex == 0
          ? null
          : _gap(session, frame, DeviceAudioGapReason.invalidStart);
    }
    final expectedPacketId = (previousPacketId + 1) & 0xffff;
    final validPacketIndex =
        frame.packetIndex == 0 ||
        frame.packetIndex == ((previousPacketIndex + 1) & 0xff);
    return frame.firstPacketId == expectedPacketId && validPacketIndex
        ? null
        : _gap(session, frame, DeviceAudioGapReason.packetDiscontinuity);
  }

  DeviceAudioGap _gap(
    _AudioSession session,
    DeviceAudioFrame frame,
    DeviceAudioGapReason reason,
  ) => DeviceAudioGap(
    deviceId: session.deviceId,
    reason: reason,
    packetId: frame.packetId,
    packetIndex: frame.packetIndex,
    previousPacketId:
        session.previousPacketId ??
        (frame.error == DeviceAudioFrameError.discontinuity
            ? frame.firstPacketId
            : null),
    previousPacketIndex: session.previousPacketIndex,
  );

  void _fail(_AudioSession session, Object error) {
    if (_session != session || !session.accepting) return;
    lastError = error;
    session.accepting = false;
    scheduleMicrotask(() => unawaited(_finish(session, abort: true)));
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
        scheduleMicrotask(() => unawaited(_finish(session, abort: true)));
        return;
      }
    }
    if (session.pending.length <= maxPendingFrames ~/ 2 &&
        (session.audioSubscription?.isPaused ?? false) &&
        session.accepting) {
      session.audioSubscription?.resume();
    }
  }

  Future<void> stop() async {
    _startGeneration += 1;
    await _stopCurrent();
  }

  Future<void> _stopCurrent() async {
    final session = _session;
    if (session != null) await _finish(session, abort: true);
  }

  Future<void> _finish(_AudioSession session, {bool abort = false}) async {
    if (abort) session.abortRequested = true;
    if (session.finishing) return session.finished.future;
    session.finishing = true;
    session.accepting = false;
    session.reconnectTimer?.cancel();
    session.reconnectTimer = null;
    if (!session.startCancelled.isCompleted) {
      session.startCancelled.complete();
    }
    Future<void>? stopping;
    if (session.abortRequested) stopping = _stopTranscription(session);
    await session.audioSubscription?.cancel();
    await session.connectionSubscription?.cancel();
    await session.drain;
    if (session.started && !session.abortRequested && !session.eosAttempted) {
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
        stopping ??= _stopTranscription(session);
      }
    } else if (session.abortRequested || !session.started) {
      stopping ??= _stopTranscription(session);
    }
    if (stopping != null) await stopping;
    session.pending.clear();
    if (_session == session) _session = null;
    if (!session.finished.isCompleted) session.finished.complete();
  }

  Future<void> _stopTranscription(_AudioSession session) {
    final existing = session.stopFuture;
    if (existing != null) return existing;
    session.stopAttempted = true;
    final stopping = _sendStopTranscription(session);
    session.stopFuture = stopping;
    return stopping;
  }

  Future<void> _sendStopTranscription(_AudioSession session) async {
    final response = Completer<TranscriptionStopAcknowledgement>();
    final subscription = hub.events.listen((event) {
      if (event case NativeEventTranscriptionStopAcknowledged(:final value)
          when value.requestId == session.stopRequestId &&
              value.audioStreamId == session.requestId &&
              !response.isCompleted) {
        response.complete(value);
      }
    });
    try {
      hub.stopTranscription(
        requestId: session.stopRequestId,
        audioStreamId: session.requestId,
      );
      final acknowledgement = await response.future.timeout(
        stopTimeout,
        onTimeout: () =>
            throw DeviceTranscriptionStopTimeout(session.requestId),
      );
      if (!acknowledgement.accepted) {
        lastError = DeviceTranscriptionStopRejected(session.requestId);
      }
    } catch (error) {
      lastError = error;
    } finally {
      await subscription.cancel();
    }
  }
}

final class _AudioSession {
  _AudioSession({
    required this.requestId,
    required this.deviceId,
    required this.encoding,
    required this.sampleRateHz,
  });

  final String requestId;
  String get startRequestId => 'start-$requestId';
  String get stopRequestId => 'stop-$requestId';
  final String deviceId;
  final AudioEncoding encoding;
  final int sampleRateHz;
  final pending = ListQueue<Uint8List>();
  final finished = Completer<void>();
  final startCancelled = Completer<void>();
  StreamSubscription<DeviceAudioFrame>? audioSubscription;
  StreamSubscription<bool>? connectionSubscription;
  Timer? reconnectTimer;
  Future<void> drain = Future.value();
  int sequence = 0;
  int? previousPacketId;
  int? previousPacketIndex;
  bool accepting = true;
  bool connected = true;
  bool started = false;
  bool finishing = false;
  bool eosAttempted = false;
  bool stopAttempted = false;
  Future<void>? stopFuture;
  bool abortRequested = false;
}
