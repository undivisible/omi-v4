import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/in_app_voice_view.dart';

void main() {
  Future<void> show(
    WidgetTester tester, {
    required ValueNotifier<double> level,
    required ValueNotifier<String> spoken,
    required ValueNotifier<String> reply,
    ValueNotifier<String?>? notice,
    VoidCallback? onDone,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: InAppVoiceView(
          level: level,
          userTranscript: spoken,
          assistantTranscript: reply,
          notice: notice,
          onDone: onDone ?? () {},
        ),
      ),
    ),
  );

  testWidgets('the waveform fills the window and the transcript sits under '
      'it', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final level = ValueNotifier<double>(0);
    addTearDown(level.dispose);
    final spoken = ValueNotifier<String>('');
    addTearDown(spoken.dispose);
    final reply = ValueNotifier<String>('');
    addTearDown(reply.dispose);

    await show(tester, level: level, spoken: spoken, reply: reply);
    expect(find.byKey(const Key('in_app_voice_waveform')), findsOneWidget);
    expect(
      find.byKey(const Key('in_app_voice_transcript_idle')),
      findsOneWidget,
    );
    final waveform = tester.getSize(
      find.byKey(const Key('in_app_voice_waveform')),
    );
    expect(waveform.width, greaterThan(600));
    expect(waveform.height, greaterThan(120));

    spoken.value = 'book the flight';
    reply.value = 'Booking it now';
    await tester.pump();
    expect(find.text('book the flight'), findsOneWidget);
    expect(find.text('Booking it now'), findsOneWidget);
    expect(find.byKey(const Key('in_app_voice_transcript_idle')), findsNothing);
    final transcript = tester.getTopLeft(
      find.byKey(const Key('in_app_voice_transcript')),
    );
    expect(
      transcript.dy,
      greaterThan(
        tester.getBottomLeft(find.byKey(const Key('in_app_voice_waveform'))).dy,
      ),
    );
  });

  testWidgets('the notice and the done affordance are wired', (tester) async {
    final level = ValueNotifier<double>(0);
    addTearDown(level.dispose);
    final spoken = ValueNotifier<String>('');
    addTearDown(spoken.dispose);
    final reply = ValueNotifier<String>('');
    addTearDown(reply.dispose);
    final notice = ValueNotifier<String?>(null);
    addTearDown(notice.dispose);
    var done = 0;

    await show(
      tester,
      level: level,
      spoken: spoken,
      reply: reply,
      notice: notice,
      onDone: () => done += 1,
    );
    expect(find.byKey(const Key('in_app_voice_notice')), findsNothing);
    notice.value = 'Live voice needs Pro — using transcription only';
    await tester.pump();
    expect(find.byKey(const Key('in_app_voice_notice')), findsOneWidget);

    await tester.tap(find.byKey(const Key('stop_listening')));
    expect(done, 1);
  });

  test('the bar profile is centre weighted', () {
    const last = InAppVoiceWaveformPainter.barCount - 1;
    const middle = last ~/ 2;
    expect(
      InAppVoiceWaveformPainter.profileAt(middle),
      greaterThan(InAppVoiceWaveformPainter.profileAt(0)),
    );
    expect(
      InAppVoiceWaveformPainter.profileAt(0),
      closeTo(InAppVoiceWaveformPainter.profileAt(last), 0.001),
    );
    expect(InAppVoiceWaveformPainter.profileAt(0), greaterThan(0));
  });

  test('the painter repaints only when the level, phase or colour move', () {
    final painter = InAppVoiceWaveformPainter(
      level: 0.4,
      phase: 1,
      color: const Color(0xff171716),
    );
    expect(
      painter.shouldRepaint(
        InAppVoiceWaveformPainter(
          level: 0.4,
          phase: 1,
          color: const Color(0xff171716),
        ),
      ),
      isFalse,
    );
    expect(
      painter.shouldRepaint(
        InAppVoiceWaveformPainter(
          level: 0.9,
          phase: 1,
          color: const Color(0xff171716),
        ),
      ),
      isTrue,
    );
  });
}
