import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/cursor_pill_controller.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  testWidgets('a paused input requests one AI completion after the debounce', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();

    await controller.summon();
    controller.inputChanged('open sl');
    // Nothing before the debounce elapses.
    await tester.pump(const Duration(milliseconds: 200));
    expect(harness.draftPrompts, isEmpty);
    await tester.pump(const Duration(milliseconds: 150));
    expect(harness.draftPrompts, hasLength(1));
    expect(harness.draftPrompts.single, contains('open sl'));

    harness.complete('open slack and check messages');
    await tester.pump();
    expect(controller.predictedRemainder('open sl'), 'ack and check messages');

    controller.dispose();
    await harness.close();
  });

  testWidgets('a bare continuation is appended to the typed text', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();

    await controller.summon();
    controller.inputChanged('open sl');
    await tester.pump(const Duration(milliseconds: 350));
    harness.complete('ack');
    await tester.pump();

    expect(controller.predictedRemainder('open sl'), 'ack');

    controller.dispose();
    await harness.close();
  });

  testWidgets('typing while a request is in flight drops its late reply', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();

    await controller.summon();
    controller.inputChanged('open sl');
    await tester.pump(const Duration(milliseconds: 350));
    expect(harness.draftPrompts, hasLength(1));

    // Further typing goes out before the first reply lands: the stale reply
    // must never flash.
    controller.inputChanged('draft an email');
    harness.complete('open slack');
    await tester.pump();
    expect(controller.predictedRemainder('open sl'), isNull);
    expect(controller.predictedRemainder('draft an email'), isNull);

    // The new text gets its own request, which shows normally.
    await tester.pump(const Duration(milliseconds: 350));
    expect(harness.draftPrompts, hasLength(2));
    harness.complete('draft an email to Luke');
    await tester.pump();
    expect(controller.predictedRemainder('draft an email'), ' to Luke');

    controller.dispose();
    await harness.close();
  });

  testWidgets('typing through the prediction keeps it until it diverges', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();

    await controller.summon();
    controller.inputChanged('open sl');
    await tester.pump(const Duration(milliseconds: 350));
    harness.complete('open slack');
    await tester.pump();
    expect(controller.predictedRemainder('open sl'), 'ack');

    // Typing along the prediction re-validates without a new request.
    controller.inputChanged('open sla');
    expect(controller.predictedRemainder('open sla'), 'ck');
    await tester.pump(const Duration(milliseconds: 350));
    expect(harness.draftPrompts, hasLength(1));

    // Diverging drops the prediction and schedules a fresh request.
    controller.inputChanged('open sx');
    expect(controller.predictedRemainder('open sx'), isNull);
    await tester.pump(const Duration(milliseconds: 350));
    expect(harness.draftPrompts, hasLength(2));
    harness.complete(null);
    await tester.pump();
    expect(controller.predictedRemainder('open sx'), isNull);

    controller.dispose();
    await harness.close();
  });

  testWidgets('short inputs never request a completion', (tester) async {
    final harness = _Harness();
    final controller = harness.controller();

    await controller.summon();
    controller.inputChanged('op');
    await tester.pump(const Duration(milliseconds: 400));
    expect(harness.draftPrompts, isEmpty);

    controller.dispose();
    await harness.close();
  });

  testWidgets('hiding the overlay clears any pending prediction', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();

    await controller.summon();
    controller.inputChanged('open sl');
    await tester.pump(const Duration(milliseconds: 350));
    harness.complete('open slack');
    await tester.pump();
    expect(controller.predictedRemainder('open sl'), 'ack');

    await controller.dismiss();
    expect(controller.predictedRemainder('open sl'), isNull);

    controller.dispose();
    await harness.close();
  });
}

final class _Harness {
  final hub = _FakeNativeHub();
  final level = ValueNotifier<double>(0);
  final draftPrompts = <String>[];
  final _pending = <Completer<String?>>[];
  DateTime now = DateTime.utc(2026, 7, 22);

  /// Completes the oldest in-flight draft request with [value].
  void complete(String? value) {
    _pending.removeAt(0).complete(value);
  }

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
