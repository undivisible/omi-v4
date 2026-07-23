import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/cursor_pill_controller.dart';
import 'package:omi/features/onboarding_screen.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  Future<void> chord(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftRight);
    await tester.pump();
  }

  /// A single chord resolves only after the double-chord window elapses.
  Future<void> singleChord(WidgetTester tester) async {
    await chord(tester);
    await tester.pump(const Duration(milliseconds: 450));
  }

  Future<void> doubleChord(WidgetTester tester) async {
    await chord(tester);
    await chord(tester);
    await tester.pump();
  }

  Widget host(
    CursorPillController controller,
    Stream<String> transcripts, {
    bool finale = false,
    double shakeProgress = 0,
    bool shakeComplete = false,
    VoidCallback? onVoiceLessonComplete,
    VoidCallback? onFinish,
  }) => MaterialApp(
    home: Scaffold(
      body: OnboardingUseStep(
        pill: controller,
        transcripts: transcripts,
        finishing: false,
        error: null,
        finale: finale,
        shakeProgress: shakeProgress,
        shakeComplete: shakeComplete,
        onVoiceLessonComplete: onVoiceLessonComplete ?? () {},
        onFinish: onFinish ?? () {},
      ),
    ),
  );

  testWidgets('the lesson walks type, then talk, then stop', (tester) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);
    var lessonDone = 0;

    await tester.pumpWidget(
      host(
        controller,
        transcripts.stream,
        onVoiceLessonComplete: () => lessonDone += 1,
      ),
    );

    expect(find.byKey(const Key('shift_left')), findsOneWidget);
    expect(find.textContaining('Press both Shift keys once'), findsOneWidget);

    // Type: a single chord summons the typing bar next to the cursor.
    await singleChord(tester);
    expect(controller.state, CursorPillState.input);
    expect(harness.voiceStarts, 0);
    expect(find.textContaining('This is where you type'), findsOneWidget);

    // Dismissing the typing bar completes the type lesson and reveals the
    // double-chord hint.
    harness.advance(const Duration(seconds: 1));
    await singleChord(tester);
    expect(controller.state, CursorPillState.hidden);
    expect(find.textContaining('tap the chord twice'), findsOneWidget);
    expect(find.byKey(const Key('shift_times_two')), findsOneWidget);

    // Talk: the double chord starts listening directly.
    harness.advance(const Duration(seconds: 1));
    await doubleChord(tester);
    expect(controller.state, CursorPillState.listening);
    expect(harness.voiceStarts, 1);
    expect(
      find.textContaining('press Esc, or the chord, to stop'),
      findsOneWidget,
    );

    // Stopping (chord or Esc) completes the voice lesson.
    harness.advance(const Duration(seconds: 1));
    await doubleChord(tester);
    expect(controller.state, CursorPillState.hidden);
    expect(lessonDone, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets('a currents phrase satisfies the voice lesson', (tester) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);
    var lessonDone = 0;

    await tester.pumpWidget(
      host(
        controller,
        transcripts.stream,
        onVoiceLessonComplete: () => lessonDone += 1,
      ),
    );

    await controller.beginVoice();
    await tester.pump();
    expect(controller.state, CursorPillState.listening);
    transcripts.add('show me my currents');
    await tester.pump();
    expect(lessonDone, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets('a silent stop still satisfies the voice lesson', (tester) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);
    var lessonDone = 0;

    await tester.pumpWidget(
      host(
        controller,
        transcripts.stream,
        onVoiceLessonComplete: () => lessonDone += 1,
      ),
    );

    await controller.beginVoice();
    await tester.pump();
    harness.advance(const Duration(seconds: 1));
    await doubleChord(tester);
    await tester.pump();

    expect(controller.state, CursorPillState.hidden);
    expect(lessonDone, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets('immediate re-chord is debounced and keeps voice up', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);

    await tester.pumpWidget(host(controller, transcripts.stream));

    await doubleChord(tester);
    expect(controller.state, CursorPillState.listening);
    await doubleChord(tester);
    // The bounced repeat is swallowed by the 500ms debounce.
    expect(controller.state, CursorPillState.listening);
    expect(harness.voiceStarts, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets('escape dismisses exactly like a repeated chord', (tester) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);
    var lessonDone = 0;

    await tester.pumpWidget(
      host(
        controller,
        transcripts.stream,
        onVoiceLessonComplete: () => lessonDone += 1,
      ),
    );

    // Esc stops listening, satisfying the voice lesson — identical to a
    // second double chord.
    await doubleChord(tester);
    expect(controller.state, CursorPillState.listening);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.state, CursorPillState.hidden);
    // Esc-stop counts as the voice lesson being satisfied (hands off to the
    // shake finale).
    expect(lessonDone, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets('the finale asks the user to press Esc and shake', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);

    await tester.pumpWidget(
      host(controller, transcripts.stream, finale: true, shakeProgress: 40),
    );

    expect(find.byKey(const Key('use_shake_finale')), findsOneWidget);
    expect(find.textContaining('shake your cursor'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    // The voice keycaps are gone in the finale.
    expect(find.byKey(const Key('shift_left')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets('keycap shimmer stays static when animations are disabled', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: OnboardingUseStep(
              pill: controller,
              transcripts: transcripts.stream,
              finishing: false,
              error: null,
              finale: false,
              shakeProgress: 0,
              shakeComplete: false,
              onVoiceLessonComplete: () {},
              onFinish: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ShaderMask), findsNothing);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });
}

final class _Harness {
  final hub = _FakeNativeHub();
  final level = ValueNotifier<double>(0);
  int voiceStarts = 0;
  DateTime now = DateTime.utc(2026, 7, 22);

  void advance(Duration duration) => now = now.add(duration);

  CursorPillController controller() => CursorPillController(
    hub: hub,
    events: hub.events,
    startVoice: () async => voiceStarts += 1,
    stopVoice: () async => '',
    cancelVoice: () async {},
    sendPrompt: (_) async => null,
    level: level,
    now: () => now,
  );

  Future<void> close() => hub.close();
}

final class _FakeNativeHub implements NativeHub {
  final _events = StreamController<NativeEvent>.broadcast(sync: true);

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  Future<void> close() => _events.close();

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  }) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
