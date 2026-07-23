import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/ax_context.dart';
import 'package:omi/features/cursor_pill.dart';
import 'package:omi/features/cursor_pill_controller.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  group('splitAssistResponse', () {
    test('reads the INLINE and ANSWER markers', () {
      final parts = splitAssistResponse(
        'INLINE: ack and check\nANSWER: Slack is your team chat.',
      );
      expect(parts.inline, 'ack and check');
      expect(parts.answer, 'Slack is your team chat.');
    });

    test('keeps a marked answer that spans several lines', () {
      final parts = splitAssistResponse(
        'INLINE: , thanks\nANSWER: Line one.\nLine two.',
      );
      expect(parts.inline, ', thanks');
      expect(parts.answer, 'Line one.\nLine two.');
    });

    test('falls back to first line inline, remainder answer', () {
      final parts = splitAssistResponse('ack\nSlack is your team chat.');
      expect(parts.inline, 'ack');
      expect(parts.answer, 'Slack is your team chat.');
    });

    test('a bare single line is all inline', () {
      final parts = splitAssistResponse('open slack and check messages');
      expect(parts.inline, 'open slack and check messages');
      expect(parts.answer, isNull);
    });

    test('empty yields nothing', () {
      final parts = splitAssistResponse('   ');
      expect(parts.inline, isNull);
      expect(parts.answer, isNull);
    });
  });

  testWidgets('the assist splits into an inline ghost and an answer bubble', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CursorPill(controller: controller)),
      ),
    );

    await controller.summon();
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('cursor_pill_input')),
      'open sl',
    );
    await tester.pump(const Duration(milliseconds: 350));
    harness.complete(
      'INLINE: ack and check messages\n'
      'ANSWER: Slack is your team chat — open it to catch up on unread threads.',
    );
    await tester.pump();

    // Inline continuation lives next to the caret; the fuller answer under it.
    expect(controller.predictedRemainder('open sl'), 'ack and check messages');
    expect(controller.answer, contains('team chat'));
    expect(find.byKey(const Key('cursor_pill_answer')), findsOneWidget);
    expect(find.textContaining('team chat'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await harness.close();
  });

  testWidgets('Tab accepts the inline suggestion into the field', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CursorPill(controller: controller)),
      ),
    );

    await controller.summon();
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('cursor_pill_input')),
      'open sl',
    );
    await tester.pump(const Duration(milliseconds: 350));
    harness.complete('INLINE: ack\nANSWER: Slack is your team chat.');
    await tester.pump();
    expect(controller.predictedRemainder('open sl'), 'ack');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.controller.text, 'open slack');
    // Tab was consumed to accept: focus stayed and the surface is still up.
    expect(controller.state, CursorPillState.input);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await harness.close();
  });

  testWidgets('continued typing discards the inline and clears the bubble', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();

    await controller.summon();
    controller.inputChanged('open sl');
    await tester.pump(const Duration(milliseconds: 350));
    harness.complete('INLINE: ack\nANSWER: Slack is your team chat.');
    await tester.pump();
    expect(controller.predictedRemainder('open sl'), 'ack');
    expect(controller.answer, isNotNull);

    // Diverging drops the inline and the now-stale bubble at once…
    controller.inputChanged('open sx');
    expect(controller.predictedRemainder('open sx'), isNull);
    expect(controller.answer, isNull);

    // …and the paused refinement re-requests exactly once (debounced).
    await tester.pump(const Duration(milliseconds: 350));
    expect(harness.draftPrompts, hasLength(2));
    harness.complete(null);

    controller.dispose();
    await harness.close();
  });

  testWidgets('with no inline suggestion, Tab is not consumed to accept', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CursorPill(controller: controller)),
      ),
    );

    await controller.summon();
    await tester.pump();
    // Below the minimum length, so no assist is ever requested: no ghost.
    await tester.enterText(find.byKey(const Key('cursor_pill_input')), 'op');
    await tester.pump(const Duration(milliseconds: 400));
    expect(harness.draftPrompts, isEmpty);
    expect(controller.predictedRemainder('op'), isNull);

    // With no ghost, Tab falls through to default focus traversal instead of
    // being swallowed; focus leaves the field and the pill dismisses.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(controller.state, CursorPillState.hidden);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await harness.close();
  });

  testWidgets('the assist prompt carries the cached on-screen context', (
    tester,
  ) async {
    final harness = _Harness(
      snapshot: const AxContextSnapshot(
        appName: 'Mail',
        surrounding: 'From: Luke\nWhat is your timeline?',
      ),
    );
    final controller = harness.controller();

    await controller.summon();
    // Let the background snapshot refresh settle into the cache.
    await tester.pump();
    controller.inputChanged('Hi Luke,');
    await tester.pump(const Duration(milliseconds: 350));

    expect(harness.draftPrompts.single, contains('App: Mail'));
    expect(harness.draftPrompts.single, contains('What is your timeline?'));
    harness.complete(null);

    controller.dispose();
    await harness.close();
  });
}

final class _Harness {
  _Harness({this.snapshot});

  final AxContextSnapshot? snapshot;
  final hub = _FakeNativeHub();
  final level = ValueNotifier<double>(0);
  final draftPrompts = <String>[];
  final _pending = <Completer<String?>>[];
  DateTime now = DateTime.utc(2026, 7, 22);

  /// Completes the oldest in-flight draft request with [value].
  void complete(String? value) => _pending.removeAt(0).complete(value);

  CursorPillController controller() => CursorPillController(
    hub: hub,
    events: hub.events,
    startVoice: () async {},
    stopVoice: () async => '',
    cancelVoice: () async {},
    sendPrompt: (_) async => null,
    draft: (prompt, timeout) {
      draftPrompts.add(prompt);
      final completer = Completer<String?>();
      _pending.add(completer);
      return completer.future;
    },
    fetchAxContext: snapshot == null ? null : () async => snapshot!,
    level: level,
    now: () => now,
  );

  Future<void> close() async {
    for (final completer in _pending) {
      if (!completer.isCompleted) completer.complete(null);
    }
    await hub.close();
  }
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
