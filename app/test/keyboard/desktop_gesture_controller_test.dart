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

  test('a shake event produces startVoice', () async {
    final h = harness();

    h.events.add(const DesktopShakeEvent());
    await Future<void>.delayed(Duration.zero);

    expect(h.actions, [ShiftGestureAction.startVoice]);
    await h.controller.dispose();
    await h.events.close();
  });

  test('the overlay keybind produces openOverlay immediately', () async {
    final h = harness();

    h.events.add(const DesktopSummonOverlayEvent());
    await Future<void>.delayed(Duration.zero);

    expect(h.actions, [ShiftGestureAction.openOverlay]);
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
    h.events.add(const DesktopSummonOverlayEvent());
    h.events.add(const DesktopShakeEvent());
    await Future<void>.delayed(window * 3);

    expect(h.actions, [ShiftGestureAction.cancel]);
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
