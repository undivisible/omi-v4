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

  testWidgets('the lesson walks talk, then stop', (tester) async {
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
    expect(
      find.textContaining('Double-tap both Shift keys to start talking'),
      findsOneWidget,
    );

    // Talk: the chord starts listening directly — no mic tap in between.
    await chord(tester);
    expect(controller.state, CursorPillState.listening);
    expect(harness.voiceStarts, 1);
    expect(
      find.textContaining('press Esc, or double-shift, to stop'),
      findsOneWidget,
    );

    // Stopping (chord or Esc) completes the voice lesson.
    harness.advance(const Duration(seconds: 1));
    await chord(tester);
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

    await chord(tester);
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

    await chord(tester);
    await controller.beginVoice();
    await tester.pump();
    harness.advance(const Duration(seconds: 1));
    await chord(tester);
    await tester.pump();

    expect(controller.state, CursorPillState.hidden);
    expect(lessonDone, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets('immediate re-chord is debounced and keeps the overlay up', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);

    await tester.pumpWidget(host(controller, transcripts.stream));

    await chord(tester);
    await chord(tester);
    // The bounced second chord is swallowed by the 500ms debounce.
    expect(controller.state, CursorPillState.listening);
    expect(harness.voiceStarts, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets('escape dismisses exactly like a second double-shift', (
    tester,
  ) async {
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
    // second chord.
    await chord(tester);
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
