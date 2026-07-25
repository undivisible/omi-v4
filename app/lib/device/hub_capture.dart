import 'dart:async';

import 'package:flutter/foundation.dart';

import '../native/native_hub.dart';

/// The client half of the pendant capture pipeline.
///
/// The write-ahead log, the upload pump and the gap accounting all live in the
/// Rust hub: there they get real `fsync` control, they are never stalled by a
/// garbage collection mid-frame, and — the reason that matters most — the log
/// outlives the Dart isolate rather than dying with it. Everything here is the
/// seam, not the policy: it turns each command into the future the capture path
/// awaits, and holds the pending count the UI renders.
///
/// Every method degrades to a no-op rather than throwing. A hub that is not
/// available, a log that could not be opened on read-only storage, a reply that
/// never came — none of those are reasons to stop recording, they are reasons
/// the recording is not durable, which is what [lastError] says.
final class HubCapture {
  HubCapture(this._hub, {this.timeout = const Duration(seconds: 15)}) {
    // One subscription for every reply, demultiplexed by request id. A
    // subscription per command would mean one per audio frame.
    _events = _hub.available
        ? _hub.events.listen(_deliver, onError: (Object _) {})
        : null;
  }

  /// How long a command waits for its single answering event before the caller
  /// is released. A capture path blocked forever on a reply that was dropped
  /// would stop recording, which is strictly worse than recording without
  /// knowing whether the last frame landed.
  final Duration timeout;

  final NativeHub _hub;
  StreamSubscription<NativeEvent>? _events;
  final _waiting = <String, Completer<Object?>>{};

  int _sequence = 0;
  bool _disposed = false;

  /// Sealed segments still on disk, for the UI to surface as "N clips waiting
  /// to upload". Durability the user cannot see is durability they will not
  /// trust.
  final pendingListenable = ValueNotifier<int>(0);

  /// The most recent reason a command did not do what it was asked. Never
  /// fatal: the audio it describes is still on disk unless the log itself
  /// failed to open.
  Object? lastError;

  /// True once the hub has reported a log it could actually open. Until then
  /// capture still runs, it simply is not durable.
  bool get durable => _directory != null;
  String? get directory => _directory;
  String? _directory;

  /// Opens (creating if needed) the log under [directory], the shared `.omi`
  /// data directory the client resolved. Returns false when the hub could not
  /// open it at all, which is reported and skipped rather than blocking
  /// capture.
  Future<bool> open({
    required String directory,
    int? maxBytes,
    int? maxAgeMs,
    int? maxSegmentBytes,
  }) async {
    final opened = await _ask<CaptureWalOpened>(
      (requestId) => _hub.openCaptureWal(
        requestId: requestId,
        directory: directory,
        maxBytes: maxBytes,
        maxAgeMs: maxAgeMs,
        maxSegmentBytes: maxSegmentBytes,
      ),
    );
    _directory = opened?.directory;
    if (opened?.error != null) lastError = opened!.error;
    return _directory != null;
  }

  /// Supplies the credentials sealed segments go up with. Passing nothing
  /// withdraws them, which leaves every segment in the log rather than
  /// dropping audio because the route was unreachable.
  void configureUpload({String? endpoint, String? firebaseToken}) => _send(
    (requestId) => _hub.configureCaptureUpload(
      requestId: requestId,
      endpoint: endpoint,
      firebaseToken: firebaseToken,
    ),
  );

  /// Seals whatever is open and starts a new segment, returning the id the
  /// transcription endpoint will deduplicate the upload on.
  Future<String?> beginSegment({
    required String deviceId,
    required String audioStreamId,
    required AudioEncoding encoding,
    required int sampleRateHz,
    required int channels,
    bool gapBefore = false,
  }) async {
    final begun = await _ask<CaptureSegmentBegun>(
      (requestId) => _hub.beginCaptureSegment(
        requestId: requestId,
        deviceId: deviceId,
        audioStreamId: audioStreamId,
        encoding: encoding,
        sampleRateHz: sampleRateHz,
        channels: channels,
        gapBefore: gapBefore,
      ),
    );
    if (begun?.error != null) lastError = begun!.error;
    return begun?.segmentId;
  }

  /// Appends one decoded frame and waits for the hub to say the bytes are with
  /// the operating system. The wait is the point: the caller hands the same
  /// frame to the transcription socket next, and disk first is what makes a
  /// frame that was in flight when the process died recoverable.
  Future<void> append(Uint8List bytes) async {
    final appended = await _ask<CaptureAudioAppended>(
      (requestId) =>
          _hub.appendCaptureAudio(requestId: requestId, bytes: bytes),
    );
    if (appended?.error != null) lastError = appended!.error;
  }

  /// Seals the open segment so it becomes uploadable. A segment left open
  /// would be skipped by the uploader forever.
  Future<void> seal() async => _publish(
    await _ask<CaptureWalState>(
      (requestId) => _hub.sealCaptureSegment(requestId),
    ),
  );

  /// Seals the open segment and releases the file handle.
  Future<void> close() async => _publish(
    await _ask<CaptureWalState>((requestId) => _hub.closeCaptureWal(requestId)),
  );

  /// Re-reads what the log is holding without uploading anything.
  Future<void> refresh() async => _publish(
    await _ask<CaptureWalState>(
      (requestId) => _hub.readCaptureWalState(requestId),
    ),
  );

  /// Runs one upload pass and returns how many segments left the log. The hub
  /// also drains on its own minute tick, so this is the "something changed,
  /// look now" path rather than the only one.
  Future<int> drain() async {
    final state = await _ask<CaptureWalState>(
      (requestId) => _hub.drainCaptureWal(requestId),
    );
    _publish(state);
    return state?.uploaded.toInt() ?? 0;
  }

  /// Records that capture stopped. The resume side arrives separately, because
  /// a device that never comes back still has a discontinuity worth showing.
  Future<void> recordGap({
    required String deviceId,
    required String reason,
    required DateTime endedAt,
    required String endedStreamId,
  }) async => _send(
    (requestId) => _hub.recordCaptureGap(
      requestId: requestId,
      deviceId: deviceId,
      reason: reason,
      endedAtMs: endedAt.toUtc().millisecondsSinceEpoch,
      endedStreamId: endedStreamId,
    ),
  );

  /// Attaches the resume side to the most recent open gap for this device.
  /// [streamId] names the NEW stream, which is what makes it impossible to read
  /// the two sides as one recording.
  Future<void> recordResume({
    required String deviceId,
    required DateTime at,
    required String streamId,
  }) async => _send(
    (requestId) => _hub.recordCaptureResume(
      requestId: requestId,
      deviceId: deviceId,
      atMs: at.toUtc().millisecondsSinceEpoch,
      streamId: streamId,
    ),
  );

  Future<List<CaptureGap>> readGaps() async {
    final gaps = await _ask<CaptureGaps>(
      (requestId) => _hub.readCaptureGaps(requestId),
    );
    return gaps?.gaps ?? const [];
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_events?.cancel());
    _events = null;
    for (final completer in _waiting.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _waiting.clear();
    pendingListenable.dispose();
  }

  void _publish(CaptureWalState? state) {
    if (state == null) return;
    if (state.lastError != null) lastError = state.lastError;
    if (!_disposed) pendingListenable.value = state.pendingSegments.toInt();
  }

  /// Sends a command that has no answering event. Failure to send is recorded
  /// rather than raised: capture must never fail because the log did not.
  void _send(void Function(String requestId) send) {
    if (_disposed || !_hub.available) return;
    try {
      send('capture-${_sequence++}');
    } catch (error) {
      lastError = error;
    }
  }

  /// Sends a command and waits for the one event that answers it, or for the
  /// timeout. Null means "no answer", never "the audio is gone".
  Future<T?> _ask<T>(void Function(String requestId) send) {
    if (_disposed || !_hub.available) return Future<T?>.value();
    final requestId = 'capture-${_sequence++}';
    final completer = Completer<Object?>();
    _waiting[requestId] = completer;
    try {
      send(requestId);
    } catch (error) {
      lastError = error;
      _waiting.remove(requestId);
      return Future<T?>.value();
    }
    return completer.future.timeout(timeout, onTimeout: () => null).then((
      value,
    ) {
      _waiting.remove(requestId);
      return value is T ? value : null;
    });
  }

  void _deliver(NativeEvent event) {
    final (String requestId, Object payload)? answer = switch (event) {
      NativeEventCaptureWalOpened(:final value) => (value.requestId, value),
      NativeEventCaptureSegmentBegun(:final value) => (value.requestId, value),
      NativeEventCaptureAudioAppended(:final value) => (value.requestId, value),
      NativeEventCaptureWalState(:final value) => (value.requestId, value),
      NativeEventCaptureGaps(:final value) => (value.requestId, value),
      _ => null,
    };
    if (answer == null) return;
    final completer = _waiting.remove(answer.$1);
    if (completer != null && !completer.isCompleted) {
      completer.complete(answer.$2);
    } else if (answer.$2 case final CaptureWalState state) {
      // The hub's own minute tick answers nobody, but it still carries the
      // freshest count of what is waiting to upload.
      _publish(state);
    }
  }
}

/// A recorded discontinuity, in the units the capture path speaks.
///
/// The two stream ids are always different: a restart opens a new stream rather
/// than continuing the old one, which is what makes the audio either side of
/// the gap impossible to re-splice.
extension CaptureGapTimes on CaptureGap {
  DateTime get endedAt =>
      DateTime.fromMillisecondsSinceEpoch(endedAtMs, isUtc: true);

  /// When capture resumed, or null while it has not.
  DateTime? get resumedAt => switch (resumedAtMs) {
    final int value => DateTime.fromMillisecondsSinceEpoch(value, isUtc: true),
    null => null,
  };

  /// How long capture was down, once it has come back.
  Duration? get duration => resumedAt?.difference(endedAt);

  CaptureGap resumed({required DateTime at, required String streamId}) =>
      CaptureGap(
        deviceId: deviceId,
        reason: reason,
        endedAtMs: endedAtMs,
        endedStreamId: endedStreamId,
        resumedAtMs: at.toUtc().millisecondsSinceEpoch,
        resumedStreamId: streamId,
      );
}
