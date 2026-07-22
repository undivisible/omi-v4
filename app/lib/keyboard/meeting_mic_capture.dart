import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../native/native_hub.dart';
import 'desktop_voice_capture.dart' show DesktopAudioStart, DesktopAudioStop;

final class MeetingMicCapture {
  MeetingMicCapture({
    required this.hub,
    this._startAudio,
    this._stopAudio,
    this._permissionCheck,
  });

  static const sampleRateHz = 16000;

  final NativeHub hub;
  final DesktopAudioStart? _startAudio;
  final DesktopAudioStop? _stopAudio;
  final Future<bool> Function()? _permissionCheck;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audio;
  String? _streamId;
  int _sequence = 0;

  bool get active => _streamId != null;

  Future<bool> hasPermission() =>
      _permissionCheck?.call() ??
      (_recorder ??= AudioRecorder()).hasPermission();

  Future<void> start({required TranscriptionAuth auth}) async {
    await stop();
    final streamId = 'meeting-mic-${DateTime.now().microsecondsSinceEpoch}';
    hub.startTranscription(
      requestId: 'start-$streamId',
      audioStreamId: streamId,
      deviceId: 'meeting-capture',
      auth: auth,
      language: 'multi',
      sampleRateHz: sampleRateHz,
      channels: 1,
      encoding: AudioEncoding.pcmS16Le,
    );
    _streamId = streamId;
    _sequence = 0;
    try {
      final audio =
          await (_startAudio?.call() ??
              (_recorder ??= AudioRecorder()).startStream(
                const RecordConfig(
                  encoder: AudioEncoder.pcm16bits,
                  sampleRate: sampleRateHz,
                  numChannels: 1,
                ),
              ));
      if (_streamId != streamId) return;
      _audio = audio.listen((bytes) {
        if (_streamId != streamId || bytes.isEmpty) return;
        hub.sendAudio(
          requestId: streamId,
          sequence: _sequence++,
          sampleRateHz: sampleRateHz,
          channels: 1,
          encoding: AudioEncoding.pcmS16Le,
          endOfStream: false,
          bytes: bytes,
        );
      }, cancelOnError: true);
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    final streamId = _streamId;
    if (streamId == null) return;
    _streamId = null;
    await _audio?.cancel();
    _audio = null;
    try {
      await (_stopAudio?.call() ?? _recorder?.stop().then((_) {}));
    } catch (_) {}
    try {
      hub.sendAudio(
        requestId: streamId,
        sequence: _sequence++,
        sampleRateHz: sampleRateHz,
        channels: 1,
        encoding: AudioEncoding.pcmS16Le,
        endOfStream: true,
        bytes: Uint8List(0),
      );
      hub.stopTranscription(
        requestId: 'stop-$streamId',
        audioStreamId: streamId,
      );
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _recorder?.dispose();
  }
}
