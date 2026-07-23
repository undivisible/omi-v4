import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../native/generated/signals/signals.dart' show NativeError;
import '../native/native_hub.dart';
import 'capture_gap_log.dart';
import 'capture_wal.dart';
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
    this.wal,
    this.gapRecorder,
    this.autoRestart = false,
    this.restartDelay = const Duration(seconds: 2),
    this.maxConsecutiveRestarts = 5,
    this.onCaptureStopped,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const maxFrameBytes = 256 * 1024;
  static const maxPendingFrames = 8;

  final DeviceRelayService relay;
  final NativeHub hub;
  final TranscriptionAuth auth;
  final String language;
  final Duration startTimeout;
  final Duration stopTimeout;
  final Duration reconnectGrace;

  /// Every frame handed to the hub is written here first, so a dropped socket,
  /// a dropped packet or a killed process leaves the audio on disk instead of
  /// losing it. Null disables durability entirely (tests, desktop observers).
  CaptureWal? wal;

  /// Where a discontinuity is recorded before capture restarts across it.
  CaptureGapRecorder? gapRecorder;

  /// Whether a session that failed for a transient reason is restarted.
  ///
  /// The abort itself is not negotiable and stays: audio either side of a gap
  /// is never spliced into one stream. Restart is the recovery half — a new
  /// STT session with a new stream id, and a recorded gap between the two.
  bool autoRestart;
  final Duration restartDelay;

  /// How many restarts may happen back to back without a session ever
  /// delivering a frame. Beyond this the pendant or the link is genuinely
  /// broken and retrying forever would just burn battery.
  final int maxConsecutiveRestarts;

  /// Called when capture ends and is not being restarted, with a short
  /// user-facing reason. Wired to the capture-stopped alert.
  void Function(String reason)? onCaptureStopped;

  final DateTime Function() _now;
  _AudioSession? _sessionValue;
  int _startGeneration = 0;
  Object? lastError;

  /// The most recent recorded discontinuity, for anything that renders capture
  /// health. A gap the user cannot see is a gap they will read as continuous
  /// audio.
  final lastGapRecord = ValueNotifier<CaptureGapRecord?>(null);

  RelayDevice? _restartDevice;
  TranscriptionAuth? _restartAuth;
  Timer? _restartTimer;
  int _consecutiveRestarts = 0;
  bool _gapBeforeNextSegment = false;

  /// Fires whenever capture starts or stops. [active] is a plain getter that a
  /// widget can only sample while it happens to be building, so a stream that
  /// starts on connect (or ends on a dropped link) would otherwise never reach
  /// the UI; anything rendering capture state listens to this instead.
  final ValueNotifier<bool> activeListenable = ValueNotifier<bool>(false);

  _AudioSession? get _session => _sessionValue;

  set _session(_AudioSession? session) {
    if (identical(_sessionValue, session)) return;
    _sessionValue = session;
    activeListenable.value = session != null;
  }

  bool get active => _session != null;
  DeviceAudioGap? get lastGap => switch (lastError) {
    final DeviceAudioGap gap => gap,
    _ => null,
  };

  Future<void> start(RelayDevice device, {TranscriptionAuth? auth}) async {
    final generation = ++_startGeneration;
    _restartTimer?.cancel();
    _restartTimer = null;
    _restartDevice = device;
    _restartAuth = auth ?? this.auth;
    // A supersede is not a failure, so the session being replaced must not
    // trigger a gap-recording restart of its own.
    _sessionValue?.intentionalStop = true;
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
    final gapBefore = _gapBeforeNextSegment;
    _gapBeforeNextSegment = false;
    await wal?.beginSegment(
      deviceId: session.deviceId,
      audioStreamId: session.requestId,
      encoding: session.encoding.name,
      sampleRateHz: session.sampleRateHz,
      channels: 1,
      gapBefore: gapBefore,
    );
    if (gapBefore) {
      // The resume side of the recorded gap. It names the NEW stream id, which
      // is what makes it impossible to read the two sides as one recording.
      await gapRecorder?.recordResume(
        deviceId: session.deviceId,
        at: _now(),
        streamId: session.requestId,
      );
      final recorded = lastGapRecord.value;
      if (recorded != null && recorded.resumedAt == null) {
        lastGapRecord.value = recorded.resumed(
          at: _now(),
          streamId: session.requestId,
        );
      }
    }
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
    // A session that is actually carrying audio has recovered; the restart
    // budget is about consecutive failures, not lifetime ones.
    _consecutiveRestarts = 0;
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
      // Disk first. If the hub throws, the socket dies or the process is
      // killed on the next line, the audio is already durable.
      try {
        await wal?.append(bytes);
      } catch (error) {
        lastError = error;
      }
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

  /// Ends capture at the user's request. Never restarts.
  Future<void> stop() async {
    _startGeneration += 1;
    _restartTimer?.cancel();
    _restartTimer = null;
    _restartDevice = null;
    _restartAuth = null;
    _consecutiveRestarts = 0;
    _sessionValue?.intentionalStop = true;
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
    // Sealing makes whatever this session captured uploadable. A segment left
    // open would be skipped by the uploader forever.
    try {
      await wal?.seal();
    } catch (error) {
      lastError = error;
    }
    if (_session == session) _session = null;
    if (!session.finished.isCompleted) session.finished.complete();
    if (session.abortRequested && !session.intentionalStop) {
      await _recover(session);
    }
  }

  /// The recovery half of the fail-closed abort: record the discontinuity,
  /// then open a *new* session rather than continuing the old one.
  ///
  /// Nothing here re-splices. The restarted session gets a new stream id, its
  /// first write-ahead segment is marked `gapBefore`, and the gap itself is a
  /// durable record with both sides' stream ids on it.
  Future<void> _recover(_AudioSession session) async {
    final device = _restartDevice;
    final reason = switch (lastError) {
      final DeviceAudioGap gap => gap.reason.name,
      _ => 'sessionFailed',
    };
    final record = CaptureGapRecord(
      deviceId: session.deviceId,
      reason: reason,
      endedAt: _now(),
      endedStreamId: session.requestId,
    );
    await gapRecorder?.record(record);
    lastGapRecord.value = record;
    // Only a packet-level gap on a still-connected link is transient enough to
    // restart from here. A dropped link is already handled by the reconnect
    // grace, and a session that died for any other reason may have lost its
    // authority with it — restarting on cached credentials would stream audio
    // the account may no longer be allowed to send.
    final transient = lastError is DeviceAudioGap && session.connected;
    if (!autoRestart ||
        !transient ||
        device == null ||
        _consecutiveRestarts >= maxConsecutiveRestarts) {
      onCaptureStopped?.call(_stoppedMessage(reason));
      return;
    }
    _consecutiveRestarts += 1;
    _gapBeforeNextSegment = true;
    final generation = _startGeneration;
    _restartTimer?.cancel();
    _restartTimer = Timer(restartDelay, () {
      if (generation != _startGeneration) return;
      final auth = _restartAuth;
      unawaited(
        start(device, auth: auth).catchError((Object error) {
          lastError = error;
          onCaptureStopped?.call(_stoppedMessage(reason));
        }),
      );
    });
  }

  static String _stoppedMessage(String reason) => switch (reason) {
    'packetDiscontinuity' => 'Audio from your Omi was interrupted.',
    'frameTooLarge' ||
    'invalidStart' => 'Your Omi sent audio Omi could not read.',
    'bufferCapacity' => 'Audio arrived faster than it could be sent.',
    _ => 'Capture stopped unexpectedly.',
  };

  void dispose() {
    _restartTimer?.cancel();
    _restartTimer = null;
    lastGapRecord.dispose();
    activeListenable.dispose();
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

  /// True when this session ended because the app asked it to (an explicit
  /// stop, or being superseded by a new start). Only unintentional endings are
  /// eligible for a gap-recording restart.
  bool intentionalStop = false;
}
