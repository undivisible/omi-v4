import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/keyboard/live_voice_capture.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  Future<LiveVoiceCapture> startedCapture(_LiveHub hub) async {
    final audio = StreamController<Uint8List>();
    addTearDown(audio.close);
    final capture = LiveVoiceCapture(
      hub: hub,
      startAudio: () async => audio.stream,
      stopAudio: () async {},
      disposeAudio: () async {},
      permissionCheck: () async => true,
    );
    final started = capture.start(
      ephemeralToken: 'auth_tokens/fake',
      model: 'gemini-live-test',
      authorityId: 'g1',
    );
    await hub.startedStream();
    hub.emitState(LiveVoicePhase.started);
    await started;
    return capture;
  }

  test('stop yields the buffered transcript when the provider ends '
      'the session', () async {
    final hub = _LiveHub();
    addTearDown(hub.close);
    final capture = await startedCapture(hub);
    hub.emitTranscript('hello ', finalSegment: true);
    hub.emitTranscript('ignored draft', finalSegment: false);
    hub.emitTranscript('world', finalSegment: true);
    hub.emitState(LiveVoicePhase.ended);
    await pumpEventQueue();
    expect(await capture.stop(), 'hello world');
    expect(capture.active, isFalse);
    await capture.dispose();
  });

  test('user cancellation still discards the buffered transcript', () async {
    final hub = _LiveHub();
    addTearDown(hub.close);
    final capture = await startedCapture(hub);
    hub.emitTranscript('do not send', finalSegment: true);
    await pumpEventQueue();
    await capture.cancel();
    expect(await capture.stop(), '');
    await capture.dispose();
  });

  test('a failed session discards the buffered transcript', () async {
    final hub = _LiveHub();
    addTearDown(hub.close);
    final capture = await startedCapture(hub);
    hub.emitTranscript('do not send', finalSegment: true);
    hub.emitState(LiveVoicePhase.failed, detail: 'provider failure');
    await pumpEventQueue();
    expect(await capture.stop(), '');
    await capture.dispose();
  });
}

final class _LiveHub implements NativeHub, LiveVoiceHub {
  final _events = StreamController<NativeEvent>.broadcast();
  String? streamId;
  final _started = Completer<void>();

  Future<void> startedStream() => _started.future;

  void emitState(LiveVoicePhase state, {String? detail}) {
    _events.add(
      NativeEventLiveVoiceState(
        value: LiveVoiceState(
          liveStreamId: streamId!,
          state: state,
          detail: detail,
        ),
      ),
    );
  }

  void emitTranscript(String text, {required bool finalSegment}) {
    _events.add(
      NativeEventLiveVoiceTranscript(
        value: LiveVoiceTranscript(
          liveStreamId: streamId!,
          text: text,
          finalSegment: finalSegment,
        ),
      ),
    );
  }

  Future<void> close() => _events.close();

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {}

  @override
  void startLiveVoice({
    required String requestId,
    required String liveStreamId,
    required String ephemeralToken,
    required String model,
  }) {
    streamId = liveStreamId;
    if (!_started.isCompleted) _started.complete();
  }

  @override
  void stopLiveVoice({
    required String requestId,
    required String liveStreamId,
  }) {}

  @override
  void sendAudio({
    required String requestId,
    required int sequence,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
    required bool endOfStream,
    required Uint8List bytes,
  }) {}

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
