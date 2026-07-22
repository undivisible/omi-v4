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

  testWidgets(
    'double-shift sequence teaches pill, voice, and completes on currents',
    (tester) async {
      final harness = _Harness();
      final controller = harness.controller();
      final transcripts = StreamController<String>.broadcast(sync: true);
      var finished = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OnboardingUseStep(
              pill: controller,
              transcripts: transcripts.stream,
              finishing: false,
              error: null,
              onFinish: () => finished += 1,
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('shift_left')), findsOneWidget);
      expect(
        find.textContaining('Press both Shift keys at the same time'),
        findsOneWidget,
      );
      await chord(tester);
      expect(controller.state, CursorPillState.input);
      expect(find.textContaining('Don’t type'), findsOneWidget);

      harness.advance(const Duration(seconds: 1));
      await chord(tester);
      expect(controller.state, CursorPillState.listening);
      expect(harness.voiceStarts, 1);
      expect(find.textContaining('Show me my currents'), findsOneWidget);
      expect(
        find.textContaining('or Esc — to stop'),
        findsOneWidget,
      );

      transcripts.add('show me my currents');
      await tester.pump();
      expect(finished, 1);

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await transcripts.close();
      await harness.close();
    },
  );

  testWidgets('stopping voice after any speech completes the lesson', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);
    var finished = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OnboardingUseStep(
            pill: controller,
            transcripts: transcripts.stream,
            finishing: false,
            error: null,
            onFinish: () => finished += 1,
          ),
        ),
      ),
    );

    await chord(tester);
    harness.advance(const Duration(seconds: 1));
    await chord(tester);
    expect(controller.state, CursorPillState.listening);

    // Something was said, but not the magic phrase.
    transcripts.add('hello there omi');
    await tester.pump();
    expect(finished, 0);

    harness.advance(const Duration(seconds: 1));
    await chord(tester);
    expect(controller.state, CursorPillState.hidden);
    expect(finished, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets(
    'a late transcript arriving after the stop still completes the lesson',
    (tester) async {
      final harness = _Harness();
      final controller = harness.controller();
      final transcripts = StreamController<String>.broadcast(sync: true);
      var finished = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OnboardingUseStep(
              pill: controller,
              transcripts: transcripts.stream,
              finishing: false,
              error: null,
              onFinish: () => finished += 1,
            ),
          ),
        ),
      );

      await chord(tester);
      harness.advance(const Duration(seconds: 1));
      await chord(tester);
      harness.advance(const Duration(seconds: 1));
      await chord(tester);
      expect(controller.state, CursorPillState.hidden);
      // The stop itself completes the lesson now.
      expect(finished, 1);

      // A transcript draining late must not double-complete.
      transcripts.add('hello omi');
      await tester.pump();
      expect(finished, 1);

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await transcripts.close();
      await harness.close();
    },
  );

  testWidgets('a silent stop still completes the lesson', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);
    var finished = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OnboardingUseStep(
            pill: controller,
            transcripts: transcripts.stream,
            finishing: false,
            error: null,
            onFinish: () => finished += 1,
          ),
        ),
      ),
    );

    await chord(tester);
    harness.advance(const Duration(seconds: 1));
    await chord(tester);
    harness.advance(const Duration(seconds: 1));
    await chord(tester);
    await tester.pump();

    expect(controller.state, CursorPillState.hidden);
    // Performing the full pill → live → stop sequence is the lesson; even a
    // stop with no recognized speech completes onboarding rather than
    // resetting to the first prompt.
    expect(finished, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets('immediate re-chord is debounced and does not start voice', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OnboardingUseStep(
            pill: controller,
            transcripts: transcripts.stream,
            finishing: false,
            error: null,
            onFinish: () {},
          ),
        ),
      ),
    );

    await chord(tester);
    await chord(tester);
    expect(controller.state, CursorPillState.input);
    expect(harness.voiceStarts, 0);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets('escape dismisses the pill back to the first prompt', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OnboardingUseStep(
            pill: controller,
            transcripts: transcripts.stream,
            finishing: false,
            error: null,
            onFinish: () {},
          ),
        ),
      ),
    );

    await chord(tester);
    expect(controller.state, CursorPillState.input);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.state, CursorPillState.hidden);
    expect(
      find.textContaining('Press both Shift keys at the same time'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets('×2 hint and shimmer show while double-shift is expected', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    final transcripts = StreamController<String>.broadcast(sync: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OnboardingUseStep(
            pill: controller,
            transcripts: transcripts.stream,
            finishing: false,
            error: null,
            onFinish: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('shift_times_two')), findsNothing);
    expect(find.byType(KeycapShimmer), findsNWidgets(2));
    expect(
      tester
          .widgetList<KeycapShimmer>(find.byType(KeycapShimmer))
          .every((shimmer) => shimmer.enabled),
      isTrue,
    );
    expect(find.byType(ShaderMask), findsNWidgets(2));

    await chord(tester);
    expect(controller.state, CursorPillState.input);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('shift_times_two')), findsOneWidget);
    expect(find.byType(ShaderMask), findsNWidgets(2));

    harness.advance(const Duration(seconds: 1));
    await chord(tester);
    expect(controller.state, CursorPillState.listening);
    expect(find.byKey(const Key('shift_times_two')), findsNothing);
    expect(
      tester
          .widgetList<KeycapShimmer>(find.byType(KeycapShimmer))
          .every((shimmer) => shimmer.enabled),
      isFalse,
    );

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transcripts.close();
    await harness.close();
  });

  testWidgets('shimmer stays static when animations are disabled', (
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
              onFinish: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('shift_times_two')), findsNothing);
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
    sendPrompt: (_) async {},
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
