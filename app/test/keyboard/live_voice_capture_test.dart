import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/keyboard/live_voice_capture.dart';
import 'package:omi/native/native_hub.dart';

const _playoutChannel = MethodChannel('omi/voice_playout');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_playoutChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('macOS playout runs start/feed/flush/stop across a session', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final calls = <MethodCall>[];
    var queuedMs = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_playoutChannel, (call) async {
          calls.add(call);
          return call.method == 'feed' ? queuedMs : null;
        });
    final hub = _FakeHub();
    final audio = StreamController<Uint8List>();
    final voice = LiveVoiceCapture(
      hub: hub,
      startAudio: () async => audio.stream,
      stopAudio: audio.close,
    );

    await voice.start(
      ephemeralToken: 'token',
      model: 'model',
      authorityId: 'user-a',
    );
    final streamId = hub.startedStreams.single;

    hub.emitAudio(streamId, [1, 2, 3, 4], sampleRateHz: 24000);
    hub.emitAudio(streamId, [5, 6], sampleRateHz: 24000);
    await _drain(voice);
    expect(calls.map((call) => call.method), ['start', 'feed', 'feed']);
    expect(calls.first.arguments, {'sampleRateHz': 24000});
    expect(voice.discardedOutputBytes, 0);

    queuedMs = 2500;
    hub.emitAudio(streamId, [7, 8], sampleRateHz: 24000);
    hub.emitAudio(streamId, [9, 10, 11], sampleRateHz: 24000);
    await _drain(voice);
    expect(calls.map((call) => call.method), [
      'start',
      'feed',
      'feed',
      'feed',
    ]);
    expect(voice.discardedOutputBytes, 3);

    hub.emitPhase(streamId, LiveVoicePhase.interrupted);
    await _drain(voice);
    expect(calls.last.method, 'flush');

    await voice.stop();
    expect(calls.last.method, 'stop');
    expect(voice.active, isFalse);
    await voice.dispose();
    await hub.close();
  });

  test('missing playout host is swallowed and chunks are counted', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_playoutChannel, null);
    final hub = _FakeHub();
    final audio = StreamController<Uint8List>();
    final voice = LiveVoiceCapture(
      hub: hub,
      startAudio: () async => audio.stream,
      stopAudio: audio.close,
    );

    await voice.start(
      ephemeralToken: 'token',
      model: 'model',
      authorityId: 'user-a',
    );
    final streamId = hub.startedStreams.single;
    hub.emitAudio(streamId, [1, 2, 3], sampleRateHz: 24000);
    hub.emitAudio(streamId, [4, 5], sampleRateHz: 24000);
    await _drain(voice);
    expect(voice.discardedOutputBytes, 5);

    expect(await voice.stop(), '');
    await voice.dispose();
    await hub.close();
  });

  test('non-macOS platforms never touch the playout channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_playoutChannel, (call) async {
          calls.add(call);
          return null;
        });
    final hub = _FakeHub();
    final audio = StreamController<Uint8List>();
    final voice = LiveVoiceCapture(
      hub: hub,
      startAudio: () async => audio.stream,
      stopAudio: audio.close,
    );

    await voice.start(
      ephemeralToken: 'token',
      model: 'model',
      authorityId: 'user-a',
    );
    final streamId = hub.startedStreams.single;
    hub.emitAudio(streamId, [1, 2, 3], sampleRateHz: 24000);
    await _drain(voice);
    expect(calls, isEmpty);
    expect(voice.discardedOutputBytes, 3);

    await voice.stop();
    expect(calls, isEmpty);
    await voice.dispose();
    await hub.close();
  });
}

Future<void> _drain(LiveVoiceCapture voice) async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _FakeHub implements NativeHub, LiveVoiceHub {
  final eventsController = StreamController<NativeEvent>.broadcast(sync: true);
  final startedStreams = <String>[];

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => eventsController.stream;

  @override
  Future<void> initialize() async {}

  @override
  void startLiveVoice({
    required String requestId,
    required String liveStreamId,
    required String ephemeralToken,
    required String model,
  }) {
    startedStreams.add(liveStreamId);
    emitPhase(liveStreamId, LiveVoicePhase.started);
  }

  @override
  void stopLiveVoice({required String requestId, required String liveStreamId}) {
    emitPhase(liveStreamId, LiveVoicePhase.ended);
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
    if (endOfStream) emitPhase(requestId, LiveVoicePhase.ended);
  }

  void emitPhase(String liveStreamId, LiveVoicePhase phase) {
    eventsController.add(
      NativeEventLiveVoiceState(
        value: LiveVoiceState(liveStreamId: liveStreamId, state: phase),
      ),
    );
  }

  void emitAudio(
    String liveStreamId,
    List<int> bytes, {
    required int sampleRateHz,
  }) {
    eventsController.add(
      NativeEventLiveVoiceAudio(
        value: LiveVoiceAudio(
          liveStreamId: liveStreamId,
          sequence: Uint64.fromBigInt(BigInt.zero),
          sampleRateHz: sampleRateHz,
          bytes: bytes,
        ),
      ),
    );
  }

  Future<void> close() => eventsController.close();

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
