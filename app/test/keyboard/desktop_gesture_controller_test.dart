import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/keyboard/keyboard.dart';

void main() {
  const window = Duration(milliseconds: 40);

  ({
    StreamController<DesktopKeyboardEvent> events,
    DesktopGestureController controller,
    List<ShiftGestureAction> actions,
  })
  harness() {
    final events = StreamController<DesktopKeyboardEvent>();
    final controller = DesktopGestureController(
      events: events.stream,
      machine: ShiftGestureMachine(doubleChordWindow: window),
    );
    final actions = <ShiftGestureAction>[];
    controller.actions.listen(actions.add);
    controller.start();
    return (events: events, controller: controller, actions: actions);
  }

  void chord(StreamController<DesktopKeyboardEvent> events) {
    events.add(const DesktopShiftEvent(key: PhysicalShift.left, pressed: true));
    events.add(
      const DesktopShiftEvent(key: PhysicalShift.right, pressed: true),
    );
    events.add(
      const DesktopShiftEvent(key: PhysicalShift.left, pressed: false),
    );
    events.add(
      const DesktopShiftEvent(key: PhysicalShift.right, pressed: false),
    );
  }

  test('one chord resolves to openOverlay once the window elapses', () async {
    final h = harness();

    chord(h.events);
    await Future<void>.delayed(Duration.zero);
    expect(h.actions, isEmpty);
    await Future<void>.delayed(window * 3);

    expect(h.actions, [ShiftGestureAction.openOverlay]);
    await h.controller.dispose();
    await h.events.close();
  });

  test('two chords inside the window produce a single voice toggle', () async {
    final h = harness();

    chord(h.events);
    chord(h.events);
    await Future<void>.delayed(Duration.zero);
    expect(h.actions, [ShiftGestureAction.toggleVoice]);
    // The pending-chord timer must not later add a spurious openOverlay.
    await Future<void>.delayed(window * 3);
    expect(h.actions, [ShiftGestureAction.toggleVoice]);

    await h.controller.dispose();
    await h.events.close();
  });

  test('secure input cancels and suppresses the chord', () async {
    final h = harness();

    h.events.add(
      const DesktopShiftEvent(key: PhysicalShift.left, pressed: true),
    );
    h.events.add(const DesktopSecureInputEvent(true));
    h.events.add(
      const DesktopShiftEvent(key: PhysicalShift.right, pressed: true),
    );
    await Future<void>.delayed(window * 3);

    expect(h.actions, [ShiftGestureAction.cancel]);
    await h.controller.dispose();
    await h.events.close();
  });

  test('the chord survives the secure-input state sent per keystroke', () async {
    final h = harness();

    for (var press = 0; press < 2; press += 1) {
      for (final (key, down) in const [
        (PhysicalShift.left, true),
        (PhysicalShift.right, true),
        (PhysicalShift.left, false),
        (PhysicalShift.right, false),
      ]) {
        h.events.add(const DesktopSecureInputEvent(false));
        h.events.add(DesktopShiftEvent(key: key, pressed: down));
      }
    }
    await Future<void>.delayed(Duration.zero);

    expect(h.actions, [ShiftGestureAction.toggleVoice]);
    await h.controller.dispose();
    await h.events.close();
  });

  test('later events do not push back the pending chord deadline', () async {
    final h = harness();

    chord(h.events);
    // The native side keeps talking while the chord waits — its secure-input
    // state precedes every keystroke. The deadline belongs to the chord.
    for (var tick = 0; tick < 3; tick += 1) {
      await Future<void>.delayed(window ~/ 2);
      h.events.add(const DesktopSecureInputEvent(false));
    }
    await Future<void>.delayed(Duration.zero);

    expect(h.actions, [ShiftGestureAction.openOverlay]);
    await h.controller.dispose();
    await h.events.close();
  });

  test('a second chord holding one Shift down still toggles voice', () async {
    final h = harness();

    h.events.add(
      const DesktopShiftEvent(key: PhysicalShift.left, pressed: true),
    );
    h.events.add(
      const DesktopShiftEvent(key: PhysicalShift.right, pressed: true),
    );
    h.events.add(
      const DesktopShiftEvent(key: PhysicalShift.right, pressed: false),
    );
    h.events.add(
      const DesktopShiftEvent(key: PhysicalShift.right, pressed: true),
    );
    await Future<void>.delayed(Duration.zero);

    expect(h.actions, [ShiftGestureAction.toggleVoice]);
    await h.controller.dispose();
    await h.events.close();
  });

  test('escape emits the shared dismissal', () async {
    final h = harness();

    h.events.add(const DesktopEscapeEvent());
    await Future<void>.delayed(Duration.zero);

    expect(h.actions, [ShiftGestureAction.escape]);
    await h.controller.dispose();
    await h.events.close();
  });
}
