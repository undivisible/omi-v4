import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/keyboard/desktop_voice_capture.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  test('cancel during stop shares the session teardown', () async {
    var releases = 0;
    final hub = _VoiceHub(onRelease: () => releases += 1);
    final audio = StreamController<Uint8List>();
    final stopBarrier = Completer<void>();
    var audioStops = 0;
    final capture = DesktopVoiceCapture(
      hub: hub,
      startAudio: () async => audio.stream,
      stopAudio: () async {
        audioStops += 1;
        await stopBarrier.future;
        await audio.close();
      },
    );

    await capture.start(
      auth: const TranscriptionAuthLocal(),
      authorityId: 'person-1',
    );
    final stopping = capture.stop();
    await _waitFor(() => audioStops == 1);
    final cancelling = capture.cancel();
    await Future<void>.delayed(Duration.zero);

    expect(audioStops, 1);
    stopBarrier.complete();
    await Future.wait([stopping, cancelling]);

    expect(audioStops, 1);
    expect(hub.nativeStops, 0);
    expect(releases, 1);
    expect(capture.active, isFalse);
    await capture.dispose();
    await hub.close();
  });
}

Future<void> _waitFor(bool Function() predicate) async {
  while (!predicate()) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _VoiceHub implements NativeHub {
  _VoiceHub({required void Function() onRelease})
    : _events = StreamController<NativeEvent>.broadcast(onCancel: onRelease);

  final StreamController<NativeEvent> _events;
  final Map<String, String> _starts = {};
  int nativeStops = 0;

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  @override
  void startTranscription({
    required String requestId,
    required String audioStreamId,
    required String deviceId,
    required TranscriptionAuth auth,
    required String language,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
  }) {
    _starts[audioStreamId] = requestId;
    _events.add(
      NativeEventTranscriptionStatus(
        value: TranscriptionStatus(
          requestId: requestId,
          audioStreamId: audioStreamId,
          state: TranscriptionState.started,
          sttEpoch: 0,
        ),
      ),
    );
  }

  @override
  void sendAudio({
    required String requestId,
    required int sequence,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
    required bool endOfStream,
    required Uint8List bytes,
  }) {
    if (!endOfStream) return;
    _events.add(
      NativeEventTranscriptionStatus(
        value: TranscriptionStatus(
          requestId: _starts.remove(requestId)!,
          audioStreamId: requestId,
          state: TranscriptionState.finished,
          sttEpoch: 0,
        ),
      ),
    );
  }

  @override
  void stopTranscription({
    required String requestId,
    required String audioStreamId,
  }) {
    nativeStops += 1;
  }

  Future<void> close() => _events.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
