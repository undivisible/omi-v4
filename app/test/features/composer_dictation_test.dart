import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/device/device.dart';
import 'package:omi/api/dev_assistant.dart';
import 'package:omi/features/chat_screen.dart';
import 'package:omi/features/composer_dictation.dart';
import 'package:omi/native/native_hub.dart';

Uint8List _tone({int samples = 1600}) {
  final data = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    data.setInt16(i * 2, 8000, Endian.little);
  }
  return data.buffer.asUint8List();
}

ComposerDictation _dictation({
  required VoiceNoteTranscriber transcribe,
  bool permitted = true,
  StreamController<Uint8List>? audio,
}) {
  final source = audio ?? StreamController<Uint8List>();
  return ComposerDictation(
    transcribe: transcribe,
    permissionCheck: () async => permitted,
    startAudio: () async => source.stream,
    stopAudio: () async {},
  );
}

void main() {
  test('a recording is transcribed into text, and nothing is sent', () async {
    final audio = StreamController<Uint8List>();
    var calls = 0;
    final dictation = _dictation(
      audio: audio,
      transcribe: (wav, length) async {
        calls += 1;
        // The endpoint is handed a WAV container, not bare samples.
        expect(utf8.decode(wav.sublist(0, 4)), 'RIFF');
        expect(length.inMilliseconds, greaterThan(0));
        return '  hello there  ';
      },
    );
    await dictation.start();
    expect(dictation.state, DictationState.recording);
    audio.add(_tone());
    await Future<void>.delayed(Duration.zero);
    expect(dictation.level.value, greaterThan(0));
    expect(await dictation.stop(), 'hello there');
    expect(calls, 1);
    expect(dictation.state, DictationState.idle);
  });

  test('a refused microphone is an explained state', () async {
    final dictation = _dictation(
      permitted: false,
      transcribe: (_, _) async => fail('should not transcribe'),
    );
    await dictation.start();
    expect(dictation.state, DictationState.denied);
    expect(dictation.message, isNotNull);
  });

  test('an unavailable model is explained, not a silent failure', () async {
    final audio = StreamController<Uint8List>();
    final dictation = _dictation(
      audio: audio,
      transcribe: (_, _) async =>
          throw const DictationUnavailable('No audio-capable model.'),
    );
    await dictation.start();
    audio.add(_tone());
    await Future<void>.delayed(Duration.zero);
    expect(await dictation.stop(), isNull);
    expect(dictation.state, DictationState.unavailable);
    expect(dictation.message, 'No audio-capable model.');
  });

  test('a 503 from the worker reads as unavailable, not as a failure', () {
    final transcribe = workerVoiceNoteTranscriber(
      ({required method, required path, body}) async =>
          (statusCode: 503, body: {'error': 'Managed speech unavailable'}),
    );
    expect(
      transcribe(_tone(), const Duration(seconds: 1)),
      throwsA(isA<DictationUnavailable>()),
    );
  });

  testWidgets('the composer microphone transcribes into the field', (
    tester,
  ) async {
    final audio = StreamController<Uint8List>();
    final dictation = _dictation(
      audio: audio,
      transcribe: (_, _) async => 'dictated words',
    );
    addTearDown(dictation.dispose);
    // localMode makes the composer ready to type in, which is what the
    // microphone follows: dictation is a way of typing.
    debugDevAssistantAccess = const DevAssistantAccess(
      credential: 'AIzaTestDevKey',
      liveModel: 'gemini-test-live',
      missingKeyHint: '',
    );
    addTearDown(() => debugDevAssistantAccess = DevAssistantAccess.none);
    final services = AppServices.forTesting(
      nativeHub: _SilentHub(),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      currentsClient: CurrentsClient(_SilentCurrentsTransport()),
    );
    addTearDown(services.dispose);
    await services.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(services: services, dictation: dictation),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('start_dictation')));
    await tester.pumpAndSettle();
    expect(dictation.state, DictationState.recording);
    audio.add(_tone());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('stop_dictation')));
    // Stopping the capture stream settles off the fake clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byKey(const Key('chat_input')));
    expect(field.controller!.text, 'dictated words');
    // Editable, not sent: the message is still sitting in the composer.
    expect(find.text('dictated words'), findsOneWidget);
  });
}

final class _SilentHub implements NativeHub {
  final _events = StreamController<NativeEvent>.broadcast();

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {}

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _SilentCurrentsTransport implements CurrentsTransport {
  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async =>
      const CurrentsResponse(statusCode: 200, body: {});
}
