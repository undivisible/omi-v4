import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../native/native_hub.dart';
import 'desktop_voice_capture.dart' show DesktopAudioStart, DesktopAudioStop;

final class LiveVoiceCapture {
  LiveVoiceCapture({
    required this.hub,
    this._startAudio,
    this._stopAudio,
    this._disposeAudio,
    this.permissionCheck,
    this.startTimeout = const Duration(seconds: 8),
    this.stopTimeout = const Duration(seconds: 5),
  });

  static const sampleRateHz = 16000;

  final NativeHub hub;
  final Duration startTimeout;
  final Duration stopTimeout;
  final Future<bool> Function()? permissionCheck;
  AudioRecorder? _recorder;
  final DesktopAudioStart? _startAudio;
  final DesktopAudioStop? _stopAudio;
  final Future<void> Function()? _disposeAudio;
  _LiveVoiceSession? _session;
  int _generation = 0;
  int _discardedOutputBytes = 0;

  bool get active => _session != null;

  /// Output audio chunks that cannot be played — no playout host on this
  /// platform, or the playout backlog exceeded its cap — are counted and
  /// dropped so the session stays drained.
  int get discardedOutputBytes => _discardedOutputBytes;

  Future<bool> hasPermission() =>
      permissionCheck?.call() ??
      (_recorder ??= AudioRecorder()).hasPermission();

  Future<void> start({
    required String ephemeralToken,
    required String model,
    required String authorityId,
  }) async {
    if (hub is! LiveVoiceHub) {
      throw const NativeHubUnavailable(
        'Live voice is unavailable on this platform.',
      );
    }
    final live = hub as LiveVoiceHub;
    await cancel();
    final generation = ++_generation;
    final streamId =
        'live-voice-$authorityId-${DateTime.now().microsecondsSinceEpoch}';
    final session = _LiveVoiceSession(streamId);
    _session = session;
    session.events = hub.events.listen((event) => _handleEvent(session, event));
    try {
      live.startLiveVoice(
        requestId: session.startRequestId,
        liveStreamId: streamId,
        ephemeralToken: ephemeralToken,
        model: model,
      );
      await Future.any<void>([
        session.started.future,
        session.cancelled.future.then(
          (_) => throw StateError('Live voice start was cancelled.'),
        ),
      ]).timeout(startTimeout);
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
        onError: (_) => unawaited(_abort(session)),
        cancelOnError: true,
      );
    } catch (_) {
      await _abort(session);
      rethrow;
    }
  }

  Future<String> stop() async {
    final session = _session;
    if (session == null) return '';
    return session.teardown ??= _finish(session);
  }

  Future<String> _finish(_LiveVoiceSession session) async {
    session.stopping = true;
    try {
      await (_stopAudio?.call() ?? _recorder!.stop().then((_) {}));
    } catch (_) {}
    try {
      if (_session == session) {
        hub.sendAudio(
          requestId: session.streamId,
          sequence: session.sequence++,
          sampleRateHz: sampleRateHz,
          channels: 1,
          encoding: AudioEncoding.pcmS16Le,
          endOfStream: true,
          bytes: Uint8List(0),
        );
        await session.ended.future.timeout(stopTimeout);
      }
    } catch (_) {
      try {
        _stopNative(session);
      } catch (_) {}
    } finally {
      await _release(session);
    }
    return session.transcript.toString().trim();
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

  void _sendAudio(_LiveVoiceSession session, Uint8List bytes) {
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

  void _handleEvent(_LiveVoiceSession session, NativeEvent event) {
    if (_session != session) return;
    if (event case NativeEventLiveVoiceState(
      :final value,
    ) when value.liveStreamId == session.streamId) {
      switch (value.state) {
        case LiveVoicePhase.started:
          if (!session.started.isCompleted) session.started.complete();
        case LiveVoicePhase.interrupted:
          session.playoutOps = session.playoutOps.then(
            (_) => session.playout.flush(),
          );
        case LiveVoicePhase.ended || LiveVoicePhase.failed:
          if (!session.started.isCompleted) {
            session.started.completeError(
              StateError(value.detail ?? 'Live voice session ended.'),
            );
          }
          if (!session.ended.isCompleted) session.ended.complete();
          if (!session.stopping) unawaited(_abort(session));
      }
    } else if (event case NativeEventLiveVoiceTranscript(
      :final value,
    ) when value.liveStreamId == session.streamId) {
      if (value.finalSegment) session.transcript.write(value.text);
    } else if (event case NativeEventLiveVoiceAudio(
      :final value,
    ) when value.liveStreamId == session.streamId) {
      _playOutput(session, value);
    } else if (event case NativeEventError(:final value)
        when value.requestId == session.startRequestId &&
            !session.started.isCompleted) {
      session.started.completeError(StateError(value.message));
    } else if (event case NativeEventError(
      :final value,
    ) when value.requestId == session.streamId) {
      if (!session.ended.isCompleted) session.ended.complete();
      unawaited(_abort(session));
    }
  }

  void _playOutput(_LiveVoiceSession session, LiveVoiceAudio chunk) {
    final bytes = Uint8List.fromList(chunk.bytes);
    session.playoutOps = session.playoutOps.then((_) async {
      final played =
          _session == session &&
          await session.playout.play(
            sampleRateHz: chunk.sampleRateHz,
            bytes: bytes,
          );
      if (!played) _discardedOutputBytes += bytes.length;
    });
  }

  Future<void> _abort(_LiveVoiceSession session) async {
    await (session.teardown ??= _cancelSession(session));
  }

  Future<String> _cancelSession(_LiveVoiceSession session) async {
    session.stopping = true;
    try {
      await (_stopAudio?.call() ?? _recorder!.stop().then((_) {}));
    } catch (_) {}
    try {
      _stopNative(session);
    } catch (_) {}
    await _release(session);
    return '';
  }

  void _stopNative(_LiveVoiceSession session) {
    if (hub is! LiveVoiceHub) return;
    (hub as LiveVoiceHub).stopLiveVoice(
      requestId: session.stopRequestId,
      liveStreamId: session.streamId,
    );
  }

  Future<void> _release(_LiveVoiceSession session) async {
    if (!session.cancelled.isCompleted) session.cancelled.complete();
    await (session.playoutOps = session.playoutOps.then(
      (_) => session.playout.stop(),
    ));
    await session.audio?.cancel();
    await session.events?.cancel();
    if (_session == session) _session = null;
  }
}

final class _LiveVoiceSession {
  _LiveVoiceSession(this.streamId);

  final String streamId;
  String get startRequestId => 'start-$streamId';
  String get stopRequestId => 'stop-$streamId';
  final started = Completer<void>();
  final cancelled = Completer<void>();
  final ended = Completer<void>();
  final transcript = StringBuffer();
  StreamSubscription<NativeEvent>? events;
  StreamSubscription<Uint8List>? audio;
  final playout = _VoicePlayout();
  Future<void> playoutOps = Future.value();
  int sequence = 0;
  bool stopping = false;
  Future<String>? teardown;
}

final class _VoicePlayout {
  static const _channel = MethodChannel('omi/voice_playout');
  static const maxQueuedMs = 2000;

  bool _disabled = false;
  bool _started = false;
  int _queuedMs = 0;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  Future<bool> play({
    required int sampleRateHz,
    required Uint8List bytes,
  }) async {
    if (!_supported || _disabled) return false;
    try {
      if (!_started) {
        await _channel.invokeMethod<void>('start', {
          'sampleRateHz': sampleRateHz,
        });
        _started = true;
        _queuedMs = 0;
      }
      if (_queuedMs > maxQueuedMs) return false;
      final queuedMs = await _channel.invokeMethod<int>('feed', {
        'bytes': bytes,
      });
      _queuedMs = queuedMs ?? 0;
      return true;
    } on MissingPluginException {
      _disabled = true;
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> flush() async {
    if (!_started || _disabled) return;
    _queuedMs = 0;
    try {
      await _channel.invokeMethod<void>('flush');
    } on MissingPluginException {
      _disabled = true;
    } on PlatformException {
      // Playback teardown failures must never break the voice session.
    }
  }

  Future<void> stop() async {
    if (!_started || _disabled) return;
    _started = false;
    _queuedMs = 0;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      _disabled = true;
    } on PlatformException {
      // Playback teardown failures must never break the voice session.
    }
  }
}
