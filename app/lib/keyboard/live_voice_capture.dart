import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../native/native_hub.dart';
import 'desktop_voice_capture.dart'
    show DesktopAudioStart, DesktopAudioStop, pcm16Rms;

final class LiveVoiceCapture {
  LiveVoiceCapture({
    required this.hub,
    this._startAudio,
    this._stopAudio,
    this._disposeAudio,
    this.permissionCheck,
    this.startTimeout = const Duration(seconds: 12),
    this.stopTimeout = const Duration(seconds: 5),
    this.playbackHangover = const Duration(milliseconds: 320),
    this.echoCancelledSource,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  static const sampleRateHz = 16000;

  final NativeHub hub;
  final Duration startTimeout;
  final Duration stopTimeout;

  /// How long after the assistant's playback drains the microphone stays
  /// muted, covering the utterance tail and room reverb the mic would
  /// otherwise re-capture. Only used on the half-duplex fallback, when the
  /// capture device could not be put into acoustic-echo-cancelling mode.
  final Duration playbackHangover;

  /// Whether an injected audio source already cancels the assistant's
  /// playback out of the microphone signal. Only consulted when [_startAudio]
  /// supplies the stream; the built-in recorder answers this from the device
  /// itself. Defaults to assuming it does not, so the half-duplex guard
  /// covers sources of unknown provenance.
  final bool? echoCancelledSource;

  /// Injectable wall clock so the half-duplex gate can be tested
  /// deterministically.
  final DateTime Function() _now;

  final Future<bool> Function()? permissionCheck;
  AudioRecorder? _recorder;
  final DesktopAudioStart? _startAudio;
  final DesktopAudioStop? _stopAudio;
  final Future<void> Function()? _disposeAudio;
  _LiveVoiceSession? _session;
  _LiveVoiceSession? _endedSession;
  int _generation = 0;
  int _discardedOutputBytes = 0;
  bool _echoCancelled = false;
  String? _ephemeralToken;
  String? _model;
  final level = ValueNotifier<double>(0);

  /// Running transcript of what the assistant said aloud, surfaced so the
  /// UI/chat can show the reply text alongside the audio.
  final assistantTranscript = ValueNotifier<String>('');

  /// Running transcript of what the user said, as the provider finalizes each
  /// segment, so the listening view can show speech landing live.
  final userTranscript = ValueNotifier<String>('');

  /// Whether the capture device is running through the platform's
  /// acoustic-echo-cancelling path. When it is, the assistant's own playback
  /// is subtracted from the microphone signal in hardware and the mic can
  /// stay open through playback, which is what makes barge-in work. When it
  /// is not, [playbackHangover] half-duplex gating stands in for it.
  bool get echoCancelled => _echoCancelled;

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
    final live = hub;
    await cancel();
    final generation = ++_generation;
    _ephemeralToken = ephemeralToken;
    _model = model;
    assistantTranscript.value = '';
    userTranscript.value = '';
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
      final audio = await _startMicrophone();
      if (_session != session || generation != _generation) {
        await (_stopAudio?.call() ?? _recorder!.stop().then((_) {}));
        return;
      }
      session.audio = audio.listen(
        (bytes) => _sendAudio(bytes),
        onError: (_) {
          final current = _session;
          if (current != null) unawaited(_abort(current));
        },
        cancelOnError: true,
      );
    } catch (_) {
      await _abort(session);
      rethrow;
    }
  }

  static RecordConfig _recordConfig({required bool echoCancel}) => RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: sampleRateHz,
    numChannels: 1,
    echoCancel: echoCancel,
  );

  /// Opens the microphone through the platform's voice-processing path.
  ///
  /// A Live API turn is full duplex: the assistant's reply plays out of the
  /// speakers while the microphone keeps streaming. Captured plain, the mic
  /// picks that playback back up, the server's voice activity detector hears
  /// the model talking over itself, barges in on its own turn and answers
  /// again — the "cuts out, then repeats" loop. macOS routes this request
  /// through the voice-processing IO unit, which subtracts the speaker
  /// signal; Google's own Live API samples capture the same way. A device
  /// that refuses voice processing falls back to plain capture, and the
  /// half-duplex guard in [_sendAudio] stands in for it.
  Future<Stream<Uint8List>> _startMicrophone() async {
    final start = _startAudio;
    if (start != null) {
      _echoCancelled = echoCancelledSource ?? false;
      return start();
    }
    final recorder = _recorder ??= AudioRecorder();
    try {
      final stream = await recorder.startStream(
        _recordConfig(echoCancel: true),
      );
      _echoCancelled = true;
      return stream;
    } catch (_) {
      final stream = await recorder.startStream(
        _recordConfig(echoCancel: false),
      );
      _echoCancelled = false;
      return stream;
    }
  }

  Future<String> stop() async {
    final session = _session ?? _endedSession;
    _endedSession = null;
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
    _endedSession = null;
    final session = _session;
    if (session != null) await _abort(session);
    _endedSession = null;
  }

  Future<void> dispose() async {
    await cancel();
    await (_disposeAudio?.call() ?? _recorder?.dispose());
  }

  void _sendAudio(Uint8List bytes) {
    final session = _session;
    if (session == null || session.stopping || bytes.isEmpty) return;
    level.value = pcm16Rms(bytes);
    // Half-duplex echo guard, used only when the capture device could not be
    // put into echo-cancelling mode. The raw input node hears the assistant's
    // own playback, and forwarding that lets the model hear itself and
    // re-respond — the audible "cuts out, then repeats" loop. Drop outbound
    // mic frames until playback has drained; the level still moves so the
    // waveform stays alive. It costs barge-in, which is why cancelling the
    // echo properly is preferred whenever the device allows it.
    if (!_echoCancelled && _now().isBefore(session.suppressOutboundUntil)) {
      return;
    }
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
          // The turn was cut: its queued audio is dropped, so the echo guard
          // must release at once or the mic would stay muted with nothing
          // playing.
          session.playbackEndsAt = _epoch;
          session.suppressOutboundUntil = _epoch;
          session.playoutOps = session.playoutOps.then(
            (_) => session.playout.flush(),
          );
        case LiveVoicePhase.ended || LiveVoicePhase.failed:
          if (value.state == LiveVoicePhase.ended &&
              session.started.isCompleted) {
            session.providerEnded = true;
          }
          if (!session.started.isCompleted) {
            session.started.completeError(
              StateError(value.detail ?? 'Live voice session ended.'),
            );
          }
          // An unexpected death (goAway, network drop) that left a
          // resumption handle behind is retried once by reconnecting with
          // that handle before giving up on the session.
          if (!session.stopping &&
              !session.resumed &&
              session.started.isCompleted &&
              value.resumptionHandle != null) {
            unawaited(_resume(session, value.resumptionHandle!));
            return;
          }
          if (!session.ended.isCompleted) session.ended.complete();
          if (!session.stopping) unawaited(_abort(session));
      }
    } else if (event case NativeEventLiveVoiceTranscript(
      :final value,
    ) when value.liveStreamId == session.streamId) {
      if (value.assistant) {
        session.assistantTranscript.write(value.text);
        assistantTranscript.value = session.assistantTranscript.toString();
      } else if (value.finalSegment) {
        session.transcript.write(value.text);
        userTranscript.value = session.transcript.toString();
      }
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

  /// Restarts a died session once with the provider's resumption handle,
  /// carrying the transcript over so the retry is invisible to callers.
  Future<void> _resume(_LiveVoiceSession dead, String handle) async {
    final token = _ephemeralToken;
    final model = _model;
    if (token == null || model == null) {
      if (!dead.ended.isCompleted) dead.ended.complete();
      await _abort(dead);
      return;
    }
    final generation = _generation;
    final live = hub;
    final session = _LiveVoiceSession('${dead.streamId}-r')
      ..resumed = true
      ..audio = dead.audio;
    session.transcript.write(dead.transcript);
    session.assistantTranscript.write(dead.assistantTranscript);
    dead.audio = null;
    await dead.events?.cancel();
    await (dead.playoutOps = dead.playoutOps.then((_) => dead.playout.stop()));
    if (!dead.cancelled.isCompleted) dead.cancelled.complete();
    if (generation != _generation || _session != dead) {
      await session.audio?.cancel();
      return;
    }
    _session = session;
    session.events = hub.events.listen((event) => _handleEvent(session, event));
    try {
      live.startLiveVoice(
        requestId: session.startRequestId,
        liveStreamId: session.streamId,
        ephemeralToken: token,
        model: model,
        resumptionHandle: handle,
      );
      await Future.any<void>([
        session.started.future,
        session.cancelled.future.then(
          (_) => throw StateError('Live voice resume was cancelled.'),
        ),
      ]).timeout(startTimeout);
    } catch (_) {
      await _abort(session);
    }
  }

  void _playOutput(_LiveVoiceSession session, LiveVoiceAudio chunk) {
    final bytes = Uint8List.fromList(chunk.bytes);
    // PCM16 mono: two bytes per frame, frames / rate seconds of playback.
    final chunkMs = chunk.sampleRateHz > 0
        ? (bytes.length ~/ 2) * 1000 ~/ chunk.sampleRateHz
        : 0;
    session.playoutOps = session.playoutOps.then((_) async {
      final played =
          _session == session &&
          await session.playout.play(
            sampleRateHz: chunk.sampleRateHz,
            bytes: bytes,
          );
      if (played) {
        // Only audio that actually reaches the speakers can echo back into
        // the mic, so only real playback arms the half-duplex guard. Chunks
        // queue faster than realtime; track a running playback-end time so
        // the mute window spans the whole queued backlog, not just one chunk.
        final now = _now();
        final base = session.playbackEndsAt.isAfter(now)
            ? session.playbackEndsAt
            : now;
        session.playbackEndsAt = base.add(Duration(milliseconds: chunkMs));
        session.suppressOutboundUntil = session.playbackEndsAt.add(
          playbackHangover,
        );
      } else {
        _discardedOutputBytes += bytes.length;
      }
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
    if (session.providerEnded) _endedSession = session;
    await _release(session);
    return session.providerEnded ? session.transcript.toString().trim() : '';
  }

  void _stopNative(_LiveVoiceSession session) {
    hub.stopLiveVoice(
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
    if (_session == session) {
      _session = null;
      level.value = 0;
    }
  }
}

final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

final class _LiveVoiceSession {
  _LiveVoiceSession(this.streamId);

  final String streamId;
  // Half-duplex echo guard state. [playbackEndsAt] is the running wall-clock
  // time the queued assistant audio finishes; [suppressOutboundUntil] adds the
  // hangover and is what gates the microphone.
  DateTime playbackEndsAt = _epoch;
  DateTime suppressOutboundUntil = _epoch;
  String get startRequestId => 'start-$streamId';
  String get stopRequestId => 'stop-$streamId';
  final started = Completer<void>();
  final cancelled = Completer<void>();
  final ended = Completer<void>();
  final transcript = StringBuffer();
  final assistantTranscript = StringBuffer();
  StreamSubscription<NativeEvent>? events;
  StreamSubscription<Uint8List>? audio;
  final playout = _VoicePlayout();
  Future<void> playoutOps = Future.value();
  int sequence = 0;
  bool stopping = false;
  bool providerEnded = false;
  bool resumed = false;
  Future<String>? teardown;
}

final class _VoicePlayout {
  static const _channel = MethodChannel('omi/voice_playout');
  static const maxQueuedMs = 2000;

  bool _disabled = false;
  bool _started = false;
  int _queuedMs = 0;
  int _sampleRateHz = 0;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  Future<bool> play({
    required int sampleRateHz,
    required Uint8List bytes,
  }) async {
    if (!_supported || _disabled) return false;
    try {
      // The engine format is fixed at start; a mid-session mime rate change
      // requires reconfiguring the player node at the new rate.
      if (_started && sampleRateHz != _sampleRateHz) {
        await _channel.invokeMethod<void>('stop');
        _started = false;
      }
      if (!_started) {
        await _channel.invokeMethod<void>('start', {
          'sampleRateHz': sampleRateHz,
        });
        _started = true;
        _sampleRateHz = sampleRateHz;
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
