import 'dart:async';

import 'package:flutter/foundation.dart';

import 'capture_upload.dart';
import 'capture_wal.dart';

/// Drains the write-ahead log into the batch transcription endpoint.
///
/// Segments go up oldest first so a listener reconstructing a day sees them in
/// capture order. Every upload carries the segment's own id as the idempotency
/// key, so a request that succeeded server-side but whose response was lost is
/// safe to repeat: the retry is deduplicated rather than transcribed twice.
///
/// A segment leaves the log in exactly three ways — accepted, recognised as a
/// duplicate, or permanently rejected. A retryable failure stops the pass and
/// leaves the whole queue intact, because uploading past a stuck segment would
/// reorder the audio.
final class CaptureWalUploader {
  CaptureWalUploader({
    required this.wal,
    required this.transport,
    this.interval = const Duration(minutes: 1),
    this.maxAttemptsPerPass = 3,
  });

  final CaptureWal wal;
  final CaptureUploadTransport transport;
  final Duration interval;

  /// How many times one segment may fail retryably inside a single pass before
  /// the pass gives up and waits for the next tick. Bounds the work done while
  /// the network is down; it never drops the segment.
  final int maxAttemptsPerPass;

  /// Sealed segments still on disk, for the UI to surface as "N clips waiting
  /// to upload". Durability the user cannot see is durability they will not
  /// trust.
  final pendingListenable = ValueNotifier<int>(0);
  Object? lastError;

  Timer? _timer;
  Future<int> _pass = Future.value(0);
  bool _draining = false;
  bool _disposed = false;

  /// Starts periodic draining and runs one pass immediately.
  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(drain()));
    unawaited(drain());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Uploads everything currently sealed. Concurrent calls share one pass.
  Future<int> drain() {
    if (_disposed) return Future.value(0);
    if (_draining) return _pass;
    _draining = true;
    final pass = _drain().whenComplete(() => _draining = false);
    _pass = pass;
    return pass;
  }

  Future<int> _drain() async {
    var uploaded = 0;
    try {
      final segments = await wal.pending();
      pendingListenable.value = segments.length;
      for (final segment in segments) {
        if (_disposed) break;
        final audio = await wal.readAudio(segment);
        if (audio == null) {
          // Evicted between listing and reading. Nothing to send.
          continue;
        }
        var attempt = 0;
        CaptureUploadResult result;
        do {
          attempt += 1;
          result = await transport.uploadSegment(segment, audio);
        } while (result.outcome == CaptureUploadOutcome.retry &&
            attempt < maxAttemptsPerPass &&
            !_disposed);
        if (result.outcome == CaptureUploadOutcome.retry) {
          lastError = result.message;
          break;
        }
        if (result.outcome == CaptureUploadOutcome.rejected) {
          lastError = result.message;
        } else {
          uploaded += 1;
        }
        await wal.remove(segment);
        pendingListenable.value = pendingListenable.value > 0
            ? pendingListenable.value - 1
            : 0;
      }
    } catch (error) {
      lastError = error;
    }
    return uploaded;
  }

  void dispose() {
    _disposed = true;
    stop();
    pendingListenable.dispose();
  }
}
