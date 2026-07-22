import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../native/native_hub.dart';

final class TranscriptCaptureConflict implements Exception {
  const TranscriptCaptureConflict(this.requestId);

  final String requestId;
}

typedef _TranscriptCaptureFingerprint = ({
  CaptureSource source,
  int occurredAtMs,
  String text,
  TranscriptLocator locator,
});

typedef _PendingTranscriptCapture = ({
  String requestId,
  _TranscriptCaptureFingerprint fingerprint,
});

final class TranscriptMemoryIngestor {
  TranscriptMemoryIngestor(this._nativeHub, this._now, this._deliverError);

  static const _completedCapacity = 256;

  final NativeHub _nativeHub;
  final DateTime Function() _now;
  final void Function(Object, [StackTrace?]) _deliverError;
  final _pending = <String, _PendingTranscriptCapture>{};
  final _ingestionByRequest = <String, String>{};
  final _completed = <String, _TranscriptCaptureFingerprint>{};
  String? _personId;
  int _authorityGeneration = 0;
  int _transportSequence = 0;

  void configure({required String personId, required int authorityGeneration}) {
    _personId = personId;
    _authorityGeneration = authorityGeneration;
  }

  void handle(NativeEvent event) {
    if (event case NativeEventMemoryCaptured(:final value)) {
      final ingestionKey = _ingestionByRequest.remove(value.requestId);
      final pending = ingestionKey == null ? null : _pending[ingestionKey];
      if (ingestionKey != null && pending?.requestId == value.requestId) {
        _pending.remove(ingestionKey);
        _completed[ingestionKey] = pending!.fingerprint;
        if (_completed.length > _completedCapacity) {
          _completed.remove(_completed.keys.first);
        }
      }
      return;
    }
    if (event case NativeEventError(:final value)) {
      final requestId = value.requestId;
      if (requestId != null && value.code != 'idempotency_conflict') {
        final ingestionKey = _ingestionByRequest.remove(requestId);
        final pending = ingestionKey == null ? null : _pending[ingestionKey];
        if (ingestionKey != null && pending?.requestId == requestId) {
          _pending.remove(ingestionKey);
        }
      }
      return;
    }
    if (event case NativeEventTranscriptDelta(:final value)) {
      if (value.deviceId == 'desktop-microphone') return;
      final personId = _personId;
      final text = value.text.trim();
      if (!value.finalSegment || text.isEmpty || personId == null) return;
      final generation = _authorityGeneration;
      final identity = [
        personId,
        value.audioStreamId,
        value.segmentId,
      ].join('\u0000');
      final ingestionKey =
          'transcript-${sha256.convert(utf8.encode(identity))}';
      final fingerprint = (
        source: CaptureSource.omiDevice,
        occurredAtMs: value.occurredAtMs,
        text: text,
        locator: TranscriptLocator(
          deviceId: value.deviceId,
          provider: value.provider,
          streamId: value.audioStreamId,
          segmentId: value.segmentId,
          startMs: value.startMs,
          endMs: value.endMs,
        ),
      );
      final pending = _pending[ingestionKey];
      final completed = _completed[ingestionKey];
      if (pending != null || completed != null) {
        if ((pending?.fingerprint ?? completed) != fingerprint) {
          _deliverError(TranscriptCaptureConflict(ingestionKey));
        }
        return;
      }
      final requestId =
          'transcript-g$_authorityGeneration-a${_transportSequence++}-$ingestionKey';
      _pending[ingestionKey] = (requestId: requestId, fingerprint: fingerprint);
      _ingestionByRequest[requestId] = ingestionKey;
      try {
        if (generation != _authorityGeneration) {
          _pending.remove(ingestionKey);
          _ingestionByRequest.remove(requestId);
          return;
        }
        _nativeHub.capture(
          requestId: requestId,
          ingestionKey: ingestionKey,
          source: CaptureSource.omiDevice,
          occurredAtMs: value.occurredAtMs,
          recordedAtMs: _now().millisecondsSinceEpoch,
          text: text,
          transcriptLocator: fingerprint.locator,
        );
      } catch (failure, stackTrace) {
        _pending.remove(ingestionKey);
        _ingestionByRequest.remove(requestId);
        _deliverError(failure, stackTrace);
      }
    }
  }

  void fence({required int authorityGeneration, required bool cancelPending}) {
    if (cancelPending) {
      for (final pending in _pending.values) {
        try {
          _nativeHub.cancel(pending.requestId);
        } catch (_) {}
      }
    }
    _personId = null;
    _authorityGeneration = authorityGeneration;
    _pending.clear();
    _ingestionByRequest.clear();
    _completed.clear();
  }
}
