import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../native/native_hub.dart';

typedef DesktopAudioStart = Future<Stream<Uint8List>> Function();
typedef DesktopAudioStop = Future<void> Function();

final class DesktopVoiceCapture {
  DesktopVoiceCapture({
    required this.hub,
    this._startAudio,
    this._stopAudio,
    this._disposeAudio,
    this.permissionCheck,
    this.startTimeout = const Duration(seconds: 5),
    this.finishTimeout = const Duration(seconds: 10),
    this.stopTimeout = const Duration(seconds: 5),
  });

  static const sampleRateHz = 16000;

  final NativeHub hub;
  final Duration startTimeout;
  final Duration finishTimeout;
  final Duration stopTimeout;
  AudioRecorder? _recorder;
  final DesktopAudioStart? _startAudio;
  final DesktopAudioStop? _stopAudio;
  final Future<void> Function()? _disposeAudio;
  final Future<bool> Function()? permissionCheck;
  _DesktopVoiceSession? _session;
  int _generation = 0;

  bool get active => _session != null;

  Future<bool> hasPermission() =>
      permissionCheck?.call() ??
      (_recorder ??= AudioRecorder()).hasPermission();

  Future<void> start({
    required TranscriptionAuth auth,
    required String authorityId,
  }) async {
    await cancel();
    final generation = ++_generation;
    final streamId =
        'desktop-voice-$authorityId-${DateTime.now().microsecondsSinceEpoch}';
    final session = _DesktopVoiceSession(streamId);
    _session = session;
    session.events = hub.events.listen((event) => _handleEvent(session, event));
    try {
      hub.startTranscription(
        requestId: session.startRequestId,
        audioStreamId: streamId,
        deviceId: 'desktop-microphone',
        auth: auth,
        language: 'multi',
        sampleRateHz: sampleRateHz,
        channels: 1,
        encoding: AudioEncoding.pcmS16Le,
      );
      final started = await Future.any<TranscriptionStatus>([
        session.started.future,
        session.cancelled.future.then(
          (_) => throw StateError('Desktop voice start was cancelled.'),
        ),
      ]).timeout(startTimeout);
      if (started.state != TranscriptionState.started) {
        throw StateError('Desktop transcription did not start.');
      }
      if (_session != session || generation != _generation) return;
      final audio =
          await (_startAudio?.call() ??
              (_recorder ??= AudioRecorder()).startStream(
                const RecordConfig(
                  encoder: AudioEncoder.pcm16bits,
                  sampleRate: sampleRateHz,
                  numChannels: 1,
                ),
              ));
      if (_session != session || generation != _generation) {
        await (_stopAudio?.call() ?? _recorder!.stop().then((_) {}));
        return;
      }
      session.audio = audio.listen(
        (bytes) => _sendAudio(session, bytes),
        onError: session.audioDone.completeError,
        onDone: session.audioDone.complete,
        cancelOnError: true,
      );
    } catch (_) {
      await _abort(session);
      rethrow;
    }
  }

  void continueCapture() {
    if (_session == null) throw StateError('Desktop voice is not active.');
  }

  Future<String> stop() async {
    final session = _session;
    if (session == null) return '';
    return session.teardown ??= _finish(session);
  }

  Future<String> _finish(_DesktopVoiceSession session) async {
    session.stopping = true;
    try {
      await (_stopAudio?.call() ?? _recorder!.stop().then((_) {}));
      if (session.audio != null) {
        await session.audioDone.future.timeout(finishTimeout);
      }
      if (_session != session) return '';
      hub.sendAudio(
        requestId: session.streamId,
        sequence: session.sequence++,
        sampleRateHz: sampleRateHz,
        channels: 1,
        encoding: AudioEncoding.pcmS16Le,
        endOfStream: true,
        bytes: Uint8List(0),
      );
      final status = await session.finished.future.timeout(finishTimeout);
      if (status.state != TranscriptionState.finished) return '';
      return session.segments.values.join(' ').trim();
    } catch (_) {
      try {
        await _stopNative(session);
      } catch (_) {}
      rethrow;
    } finally {
      await _release(session);
    }
  }

  Future<void> cancel() async {
    _generation += 1;
    final session = _session;
    if (session != null) await _abort(session);
  }

  Future<void> dispose() async {
    await cancel();
    await (_disposeAudio?.call() ?? _recorder?.dispose());
  }

  void _sendAudio(_DesktopVoiceSession session, Uint8List bytes) {
    if (_session != session || bytes.isEmpty) return;
    hub.sendAudio(
      requestId: session.streamId,
      sequence: session.sequence++,
      sampleRateHz: sampleRateHz,
      channels: 1,
      encoding: AudioEncoding.pcmS16Le,
      endOfStream: false,
      bytes: bytes,
    );
  }

  void _handleEvent(_DesktopVoiceSession session, NativeEvent event) {
    if (_session != session) return;
    if (event case NativeEventTranscriptionStatus(
      :final value,
    ) when value.audioStreamId == session.streamId) {
      if (!session.started.isCompleted &&
          value.requestId == session.startRequestId) {
        session.started.complete(value);
      }
      if (!session.finished.isCompleted &&
          (value.state == TranscriptionState.finished ||
              value.state == TranscriptionState.cancelled ||
              value.state == TranscriptionState.failed)) {
        session.finished.complete(value);
        if (!session.stopping) unawaited(_abort(session));
      }
    } else if (event case NativeEventTranscriptDelta(
      :final value,
    ) when value.audioStreamId == session.streamId) {
      final text = value.text.trim();
      if (value.finalSegment && text.isNotEmpty) {
        session.segments[value.segmentSequence.toInt()] = text;
      }
    } else if (event case NativeEventError(:final value)
        when value.requestId == session.startRequestId &&
            !session.started.isCompleted) {
      session.started.completeError(StateError(value.message));
    } else if (event case NativeEventError(
      :final value,
    ) when value.requestId == session.streamId) {
      if (!session.finished.isCompleted) {
        session.finished.complete(
          TranscriptionStatus(
            requestId: session.startRequestId,
            audioStreamId: session.streamId,
            state: TranscriptionState.failed,
            sttEpoch: 0,
          ),
        );
      }
      unawaited(_abort(session));
    }
  }

  Future<void> _abort(_DesktopVoiceSession session) async {
    await (session.teardown ??= _cancelSession(session));
  }

  Future<String> _cancelSession(_DesktopVoiceSession session) async {
    session.stopping = true;
    try {
      await (_stopAudio?.call() ?? _recorder!.stop().then((_) {}));
    } catch (_) {}
    try {
      await _stopNative(session);
    } catch (_) {}
    await _release(session);
    return '';
  }

  Future<void> _stopNative(_DesktopVoiceSession session) async {
    final acknowledged = Completer<TranscriptionStopAcknowledgement>();
    final subscription = hub.events.listen((event) {
      if (event case NativeEventTranscriptionStopAcknowledged(:final value)
          when value.requestId == session.stopRequestId &&
              value.audioStreamId == session.streamId &&
              !acknowledged.isCompleted) {
        acknowledged.complete(value);
      }
    });
    try {
      hub.stopTranscription(
        requestId: session.stopRequestId,
        audioStreamId: session.streamId,
      );
      await acknowledged.future.timeout(stopTimeout);
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _release(_DesktopVoiceSession session) async {
    if (!session.cancelled.isCompleted) session.cancelled.complete();
    await session.audio?.cancel();
    await session.events?.cancel();
    if (_session == session) _session = null;
  }
}

final class _DesktopVoiceSession {
  _DesktopVoiceSession(this.streamId);

  final String streamId;
  String get startRequestId => 'start-$streamId';
  String get stopRequestId => 'stop-$streamId';
  final started = Completer<TranscriptionStatus>();
  final cancelled = Completer<void>();
  final finished = Completer<TranscriptionStatus>();
  final audioDone = Completer<void>();
  final segments = SplayTreeMap<int, String>();
  StreamSubscription<NativeEvent>? events;
  StreamSubscription<Uint8List>? audio;
  int sequence = 0;
  bool stopping = false;
  Future<String>? teardown;
}
