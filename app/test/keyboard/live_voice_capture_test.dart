import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/keyboard/live_voice_capture.dart';
import 'package:omi/native/native_hub.dart';

const _playoutChannel = MethodChannel('omi/voice_playout');

void main() {
  Future<LiveVoiceCapture> startedCapture(
    _LiveHub hub, {
    StreamController<Uint8List>? mic,
  }) async {
    final audio = mic ?? StreamController<Uint8List>();
    if (mic == null) addTearDown(audio.close);
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

  test('mic audio streams to the hub, drives the level, and transcripts '
      'come back', () async {
    final hub = _LiveHub();
    addTearDown(hub.close);
    final mic = StreamController<Uint8List>();
    addTearDown(mic.close);
    final capture = await startedCapture(hub, mic: mic);
    final levels = <double>[];
    capture.level.addListener(() => levels.add(capture.level.value));

    // A loud PCM16 frame must reach the hub as-is and raise the level.
    final loud = Uint8List.fromList(
      List.generate(320, (i) => i.isEven ? 0x00 : 0x40),
    );
    mic.add(loud);
    await pumpEventQueue();
    expect(hub.sentAudio, [loud]);
    expect(levels, isNotEmpty);
    expect(levels.last, greaterThan(0.3));

    hub.emitTranscript('show me my currents', finalSegment: true);
    hub.emitState(LiveVoicePhase.ended);
    await pumpEventQueue();
    expect(await capture.stop(), 'show me my currents');
    expect(capture.level.value, 0);
    await capture.dispose();
  });

  test('assistant transcripts are surfaced separately and never leak into '
      'the user transcript', () async {
    final hub = _LiveHub();
    addTearDown(hub.close);
    final capture = await startedCapture(hub);
    hub.emitTranscript('user words', finalSegment: true);
    hub.emitTranscript('assistant ', finalSegment: false, assistant: true);
    hub.emitTranscript('reply', finalSegment: true, assistant: true);
    hub.emitState(LiveVoicePhase.ended);
    await pumpEventQueue();
    expect(capture.assistantTranscript.value, 'assistant reply');
    expect(await capture.stop(), 'user words');
    await capture.dispose();
  });

  test('an unexpected session death with a resumption handle restarts once '
      'with that handle and keeps the transcript', () async {
    final hub = _LiveHub();
    addTearDown(hub.close);
    final capture = await startedCapture(hub);
    hub.emitTranscript('first half ', finalSegment: true);
    // Provider dies unexpectedly (goAway/network) but leaves a handle.
    hub.emitState(LiveVoicePhase.ended, resumptionHandle: 'handle-1');
    await pumpEventQueue();
    // The capture reconnected once, passing the handle through.
    expect(hub.startedStreams, hasLength(2));
    expect(hub.resumptionHandles, [null, 'handle-1']);
    expect(capture.active, isTrue);
    hub.emitState(LiveVoicePhase.started);
    await pumpEventQueue();
    hub.emitTranscript('second half', finalSegment: true);
    hub.emitState(LiveVoicePhase.ended);
    await pumpEventQueue();
    expect(await capture.stop(), 'first half second half');
    await capture.dispose();
  });

  test('a resumed session that dies again is not resumed twice', () async {
    final hub = _LiveHub();
    addTearDown(hub.close);
    final capture = await startedCapture(hub);
    hub.emitState(LiveVoicePhase.ended, resumptionHandle: 'handle-1');
    await pumpEventQueue();
    expect(hub.startedStreams, hasLength(2));
    hub.emitState(LiveVoicePhase.started);
    await pumpEventQueue();
    hub.emitState(LiveVoicePhase.ended, resumptionHandle: 'handle-2');
    await pumpEventQueue();
    expect(hub.startedStreams, hasLength(2));
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
    expect(calls.map((call) => call.method), ['start', 'feed', 'feed', 'feed']);
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

  test(
    'a mid-session output rate change reconfigures the playout node',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_playoutChannel, (call) async {
            calls.add(call);
            return call.method == 'feed' ? 0 : null;
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
      hub.emitAudio(streamId, [1, 2], sampleRateHz: 24000);
      hub.emitAudio(streamId, [3, 4], sampleRateHz: 16000);
      hub.emitAudio(streamId, [5, 6], sampleRateHz: 16000);
      await _drain(voice);
      expect(calls.map((call) => call.method), [
        'start',
        'feed',
        'stop',
        'start',
        'feed',
        'feed',
      ]);
      expect(calls.first.arguments, {'sampleRateHz': 24000});
      expect(calls[3].arguments, {'sampleRateHz': 16000});
      expect(voice.discardedOutputBytes, 0);

      await voice.stop();
      await voice.dispose();
      await hub.close();
    },
  );

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

  test('mic frames are muted while the assistant is playing out and reopen '
      'after the hangover', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_playoutChannel, (call) async {
          return call.method == 'feed' ? 0 : null;
        });
    var now = DateTime.fromMillisecondsSinceEpoch(1000000);
    final hub = _LiveHub();
    addTearDown(hub.close);
    final mic = StreamController<Uint8List>();
    addTearDown(mic.close);
    final capture = LiveVoiceCapture(
      hub: hub,
      startAudio: () async => mic.stream,
      stopAudio: () async {},
      disposeAudio: () async {},
      permissionCheck: () async => true,
      playbackHangover: const Duration(milliseconds: 300),
      clock: () => now,
    );
    final started = capture.start(
      ephemeralToken: 'auth_tokens/fake',
      model: 'gemini-live-test',
      authorityId: 'g1',
    );
    await hub.startedStream();
    hub.emitState(LiveVoicePhase.started);
    await started;

    final frame = Uint8List.fromList(
      List.generate(320, (i) => i.isEven ? 0x00 : 0x40),
    );

    // Before any playback the mic streams normally.
    mic.add(frame);
    await pumpEventQueue();
    expect(hub.sentAudio, hasLength(1));

    // 1000 frames of 16kHz PCM16 = 100ms of playout; with the 300ms hangover
    // the guard mutes the mic until 400ms from now.
    hub.emitAudio(List<int>.filled(3200, 1), sampleRateHz: 16000);
    await pumpEventQueue();
    mic.add(frame);
    await pumpEventQueue();
    expect(hub.sentAudio, hasLength(1), reason: 'muted during playback');

    // Still inside the hangover window.
    now = now.add(const Duration(milliseconds: 350));
    mic.add(frame);
    await pumpEventQueue();
    expect(hub.sentAudio, hasLength(1), reason: 'muted during hangover');

    // Past the playback tail plus hangover: the mic reopens.
    now = now.add(const Duration(milliseconds: 100));
    mic.add(frame);
    await pumpEventQueue();
    expect(hub.sentAudio, hasLength(2), reason: 'reopened after hangover');

    hub.emitState(LiveVoicePhase.ended);
    await pumpEventQueue();
    await capture.stop();
    await capture.dispose();
  });

  test('a barge-in interrupt releases the mic guard immediately', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_playoutChannel, (call) async {
          return call.method == 'feed' ? 0 : null;
        });
    final now = DateTime.fromMillisecondsSinceEpoch(1000000);
    final hub = _LiveHub();
    addTearDown(hub.close);
    final mic = StreamController<Uint8List>();
    addTearDown(mic.close);
    final capture = LiveVoiceCapture(
      hub: hub,
      startAudio: () async => mic.stream,
      stopAudio: () async {},
      disposeAudio: () async {},
      permissionCheck: () async => true,
      playbackHangover: const Duration(seconds: 5),
      clock: () => now,
    );
    final started = capture.start(
      ephemeralToken: 'auth_tokens/fake',
      model: 'gemini-live-test',
      authorityId: 'g1',
    );
    await hub.startedStream();
    hub.emitState(LiveVoicePhase.started);
    await started;

    final frame = Uint8List.fromList(
      List.generate(320, (i) => i.isEven ? 0x00 : 0x40),
    );
    hub.emitAudio(List<int>.filled(3200, 1), sampleRateHz: 16000);
    await pumpEventQueue();
    mic.add(frame);
    await pumpEventQueue();
    expect(hub.sentAudio, isEmpty, reason: 'muted while playing');

    // An interrupt drops the queued audio, so the guard must lift at once even
    // though the (long) hangover has not elapsed on the frozen clock.
    hub.emitState(LiveVoicePhase.interrupted);
    await pumpEventQueue();
    mic.add(frame);
    await pumpEventQueue();
    expect(hub.sentAudio, hasLength(1), reason: 'reopened on interrupt');

    hub.emitState(LiveVoicePhase.ended);
    await pumpEventQueue();
    await capture.stop();
    await capture.dispose();
  });

  test('an echo-cancelling capture device keeps the mic open through '
      'playback so barge-in still works', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_playoutChannel, (call) async {
          return call.method == 'feed' ? 0 : null;
        });
    final hub = _LiveHub();
    addTearDown(hub.close);
    final mic = StreamController<Uint8List>();
    addTearDown(mic.close);
    final capture = LiveVoiceCapture(
      hub: hub,
      startAudio: () async => mic.stream,
      stopAudio: () async {},
      disposeAudio: () async {},
      permissionCheck: () async => true,
      playbackHangover: const Duration(seconds: 5),
      echoCancelledSource: true,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000000),
    );
    final started = capture.start(
      ephemeralToken: 'auth_tokens/fake',
      model: 'gemini-live-test',
      authorityId: 'g1',
    );
    await hub.startedStream();
    hub.emitState(LiveVoicePhase.started);
    await started;
    expect(capture.echoCancelled, isTrue);

    final frame = Uint8List.fromList(
      List.generate(320, (i) => i.isEven ? 0x00 : 0x40),
    );
    hub.emitAudio(List<int>.filled(3200, 1), sampleRateHz: 16000);
    await pumpEventQueue();
    mic.add(frame);
    await pumpEventQueue();
    expect(
      hub.sentAudio,
      hasLength(1),
      reason: 'the hardware removes the echo, so the mic stays open',
    );

    hub.emitState(LiveVoicePhase.ended);
    await pumpEventQueue();
    await capture.stop();
    await capture.dispose();
  });

  test('the live transcript is published as segments finalize', () async {
    final hub = _LiveHub();
    addTearDown(hub.close);
    final capture = await startedCapture(hub);
    hub.emitTranscript('book the ', finalSegment: true);
    hub.emitTranscript('draft', finalSegment: false);
    hub.emitTranscript('flight', finalSegment: true);
    hub.emitTranscript('on it', finalSegment: true, assistant: true);
    await pumpEventQueue();
    expect(capture.userTranscript.value, 'book the flight');
    expect(capture.assistantTranscript.value, 'on it');
    hub.emitState(LiveVoicePhase.ended);
    await pumpEventQueue();
    await capture.stop();
    await capture.dispose();
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

final class _LiveHub implements NativeHub, LiveVoiceHub {
  final _events = StreamController<NativeEvent>.broadcast();
  String? streamId;
  final sentAudio = <Uint8List>[];
  final startedStreams = <String>[];
  final resumptionHandles = <String?>[];
  final _started = Completer<void>();

  Future<void> startedStream() => _started.future;

  void emitState(
    LiveVoicePhase state, {
    String? detail,
    String? resumptionHandle,
  }) {
    _events.add(
      NativeEventLiveVoiceState(
        value: LiveVoiceState(
          liveStreamId: streamId!,
          state: state,
          detail: detail,
          resumptionHandle: resumptionHandle,
        ),
      ),
    );
  }

  void emitTranscript(
    String text, {
    required bool finalSegment,
    bool assistant = false,
  }) {
    _events.add(
      NativeEventLiveVoiceTranscript(
        value: LiveVoiceTranscript(
          liveStreamId: streamId!,
          text: text,
          finalSegment: finalSegment,
          assistant: assistant,
        ),
      ),
    );
  }

  void emitAudio(List<int> bytes, {required int sampleRateHz}) {
    _events.add(
      NativeEventLiveVoiceAudio(
        value: LiveVoiceAudio(
          liveStreamId: streamId!,
          sequence: Uint64.fromBigInt(BigInt.zero),
          sampleRateHz: sampleRateHz,
          bytes: bytes,
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
    String? resumptionHandle,
  }) {
    streamId = liveStreamId;
    startedStreams.add(liveStreamId);
    resumptionHandles.add(resumptionHandle);
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
  }) {
    if (bytes.isNotEmpty) sentAudio.add(bytes);
  }

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
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
    String? resumptionHandle,
  }) {
    startedStreams.add(liveStreamId);
    emitPhase(liveStreamId, LiveVoicePhase.started);
  }

  @override
  void stopLiveVoice({
    required String requestId,
    required String liveStreamId,
  }) {
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
