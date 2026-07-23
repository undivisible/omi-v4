// The capture hooks are private fields with public constructor arguments, which
// a named parameter cannot be an initializing formal for.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Dictation for the chat composer: hold the microphone, speak, stop, and the
/// text lands in the field for the user to edit. It never sends the message —
/// speaking is a way of typing here, not a way of submitting.
///
/// The audio is one short buffer rather than a live stream, so it takes the
/// asynchronous path: the Worker's batch transcription endpoint, which selects
/// the cheapest model that declares audio input (the balanced model) through
/// the capability-aware router. Realtime conversation is a different feature
/// with a different provider (Gemini Live) and is untouched by this.
enum DictationState {
  idle,

  /// Capturing audio; the mark pulses and the button offers to stop.
  recording,

  /// Audio captured, waiting on the transcript.
  transcribing,

  /// The microphone permission was refused. Explained, never silent.
  denied,

  /// No configured model can accept audio, or the account cannot reach one.
  unavailable,

  /// The attempt failed for some other reason and can be retried.
  failed,
}

/// Transcribes a finished recording. Returns the text, or throws to signal the
/// difference between "no model can do this" and "that did not work".
typedef VoiceNoteTranscriber =
    Future<String> Function(Uint8List wav, Duration length);

/// Raised when transcription is not available at all: no audio-capable model is
/// configured, or the account is not entitled to reach one. A different state
/// from a failure, because retrying changes nothing.
final class DictationUnavailable implements Exception {
  const DictationUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

const int _dictationSampleRateHz = 16000;
const Duration _maximumDictation = Duration(minutes: 5);

/// Wraps raw 16-bit little-endian mono PCM in a WAV container, which is what
/// the transcription endpoint accepts and what the model is handed.
Uint8List wavFromPcm16(
  Uint8List pcm, {
  int sampleRateHz = _dictationSampleRateHz,
}) {
  final header = ByteData(44);
  final byteRate = sampleRateHz * 2;
  header.setUint32(0, 0x52494646, Endian.big); // "RIFF"
  header.setUint32(4, 36 + pcm.length, Endian.little);
  header.setUint32(8, 0x57415645, Endian.big); // "WAVE"
  header.setUint32(12, 0x666d7420, Endian.big); // "fmt "
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, sampleRateHz, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  header.setUint32(36, 0x64617461, Endian.big); // "data"
  header.setUint32(40, pcm.length, Endian.little);
  final out = BytesBuilder(copy: false)
    ..add(header.buffer.asUint8List())
    ..add(pcm);
  return out.takeBytes();
}

/// Root-mean-square level of a PCM16 block, scaled the way the voice overlay
/// scales it so the composer mark and the orb read the same loudness.
double dictationLevel(Uint8List bytes) {
  final samples = bytes.length ~/ 2;
  if (samples == 0) return 0;
  final data = ByteData.sublistView(bytes, 0, samples * 2);
  var sum = 0.0;
  for (var i = 0; i < samples; i++) {
    final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
    sum += sample * sample;
  }
  return math.min(1.0, math.sqrt(sum / samples) * 4);
}

final class ComposerDictation extends ChangeNotifier {
  ComposerDictation({
    required VoiceNoteTranscriber transcribe,
    AudioRecorder? recorder,
    Future<bool> Function()? permissionCheck,
    Future<Stream<Uint8List>> Function()? startAudio,
    Future<void> Function()? stopAudio,
  }) : _transcribe = transcribe,
       _recorder = recorder,
       _permissionCheck = permissionCheck,
       _startAudio = startAudio,
       _stopAudio = stopAudio;

  final VoiceNoteTranscriber _transcribe;
  final Future<bool> Function()? _permissionCheck;
  final Future<Stream<Uint8List>> Function()? _startAudio;
  final Future<void> Function()? _stopAudio;
  AudioRecorder? _recorder;

  final _captured = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _audio;
  DictationState _state = DictationState.idle;
  String? _message;

  /// Loudness of the most recent audio block, for the recording mark.
  final level = ValueNotifier<double>(0);

  DictationState get state => _state;

  /// Why the current state happened, when there is anything worth saying.
  String? get message => _message;

  bool get busy =>
      _state == DictationState.recording ||
      _state == DictationState.transcribing;

  void _moveTo(DictationState state, [String? message]) {
    _state = state;
    _message = message;
    notifyListeners();
  }

  /// Begins recording. A refused permission is an explained state, not a
  /// button that quietly does nothing.
  Future<void> start() async {
    if (busy) return;
    _captured.clear();
    final permitted = await _hasPermission();
    if (!permitted) {
      _moveTo(
        DictationState.denied,
        'Microphone access is off. Turn it on in system settings to dictate.',
      );
      return;
    }
    try {
      final audio =
          await (_startAudio?.call() ??
              (_recorder ??= AudioRecorder()).startStream(
                const RecordConfig(
                  encoder: AudioEncoder.pcm16bits,
                  sampleRate: _dictationSampleRateHz,
                  numChannels: 1,
                ),
              ));
      _audio = audio.listen(
        _collect,
        onError: (Object _) => unawaited(_abandon()),
        cancelOnError: true,
      );
    } catch (error) {
      _moveTo(DictationState.failed, 'Could not start recording.');
      return;
    }
    level.value = 0;
    _moveTo(DictationState.recording);
  }

  Future<bool> _hasPermission() async {
    try {
      return await (_permissionCheck?.call() ??
          (_recorder ??= AudioRecorder()).hasPermission());
    } catch (_) {
      return false;
    }
  }

  void _collect(Uint8List bytes) {
    if (_state != DictationState.recording || bytes.isEmpty) return;
    // A runaway recording is capped rather than left to grow past what the
    // endpoint will accept; stopping here still keeps everything said so far.
    if (_captured.length >=
        _dictationSampleRateHz * 2 * _maximumDictation.inSeconds) {
      unawaited(stop());
      return;
    }
    _captured.add(bytes);
    level.value = dictationLevel(bytes);
  }

  /// Stops recording and returns the transcript, or null when there is nothing
  /// to insert. The caller puts the text in the composer; nothing is sent.
  Future<String?> stop() async {
    if (_state != DictationState.recording) return null;
    _moveTo(DictationState.transcribing);
    level.value = 0;
    await _stopCapture();
    final pcm = _captured.takeBytes();
    if (pcm.isEmpty) {
      _moveTo(DictationState.idle);
      return null;
    }
    final seconds = pcm.length / (_dictationSampleRateHz * 2);
    try {
      final text = await _transcribe(
        wavFromPcm16(pcm),
        Duration(milliseconds: math.max(1, (seconds * 1000).round())),
      );
      _moveTo(DictationState.idle);
      return text.trim().isEmpty ? null : text.trim();
    } on DictationUnavailable catch (error) {
      _moveTo(DictationState.unavailable, error.message);
      return null;
    } catch (_) {
      _moveTo(DictationState.failed, 'That did not transcribe. Try again.');
      return null;
    }
  }

  /// Drops the recording without transcribing it.
  Future<void> cancel() async {
    if (!busy) return;
    await _abandon();
  }

  Future<void> _abandon() async {
    await _stopCapture();
    _captured.clear();
    level.value = 0;
    _moveTo(DictationState.idle);
  }

  Future<void> _stopCapture() async {
    await _audio?.cancel();
    _audio = null;
    try {
      await (_stopAudio?.call() ?? _recorder?.stop().then((_) {}));
    } catch (_) {}
  }

  /// Clears an explained state once the user has seen it.
  void acknowledge() {
    if (_state == DictationState.idle || busy) return;
    _moveTo(DictationState.idle);
  }

  @override
  void dispose() {
    unawaited(_audio?.cancel());
    unawaited(_recorder?.dispose());
    level.dispose();
    super.dispose();
  }
}

/// Posts a recording to the Worker's batch transcription endpoint. The model is
/// chosen server-side by capability, so no model id is named here.
VoiceNoteTranscriber workerVoiceNoteTranscriber(
  Future<({int statusCode, Object? body})> Function({
    required String method,
    required String path,
    Map<String, Object?>? body,
  })
  send, {
  String path = '/api/v1/speech/transcriptions',
}) {
  return (Uint8List wav, Duration length) async {
    final response = await send(
      method: 'POST',
      path: path,
      body: {
        'clientMessageId': 'dictation:${DateTime.now().microsecondsSinceEpoch}',
        'format': 'wav',
        'durationSeconds': math.max(1, length.inSeconds),
        'audio': base64Encode(wav),
      },
    );
    final body = response.body;
    final error = body is Map<String, Object?> && body['error'] is String
        ? body['error']! as String
        : null;
    if (response.statusCode == 200) {
      final text = body is Map<String, Object?> ? body['text'] : null;
      return text is String ? text : '';
    }
    // 403 is "not entitled", 503 is "no audio-capable model configured". Both
    // are states a retry will not change, so they are explained as such.
    if (response.statusCode == 403 || response.statusCode == 503) {
      throw DictationUnavailable(
        error ?? 'Dictation is unavailable on this account.',
      );
    }
    throw StateError(error ?? 'Transcription failed (${response.statusCode})');
  };
}
