import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/keyboard/keyboard.dart';

void main() {
  test('physical left and right shift events produce a tap action', () async {
    final events = StreamController<DesktopKeyboardEvent>();
    var now = DateTime.fromMillisecondsSinceEpoch(0);
    final controller = DesktopGestureController(
      events: events.stream,
      now: () => now,
    );
    final actions = <ShiftGestureAction>[];
    final subscription = controller.actions.listen(actions.add);
    controller.start();

    events.add(const DesktopShiftEvent(key: PhysicalShift.left, pressed: true));
    now = DateTime.fromMillisecondsSinceEpoch(20);
    events.add(
      const DesktopShiftEvent(key: PhysicalShift.right, pressed: true),
    );
    now = DateTime.fromMillisecondsSinceEpoch(100);
    events.add(
      const DesktopShiftEvent(key: PhysicalShift.left, pressed: false),
    );
    await Future<void>.delayed(Duration.zero);

    expect(actions, [ShiftGestureAction.openTextInput]);
    await subscription.cancel();
    await controller.dispose();
    await events.close();
  });

  test('secure input cancels pending input and suppresses its chord', () async {
    final events = StreamController<DesktopKeyboardEvent>();
    final controller = DesktopGestureController(events: events.stream);
    final actions = <ShiftGestureAction>[];
    final subscription = controller.actions.listen(actions.add);
    controller.start();

    events.add(const DesktopShiftEvent(key: PhysicalShift.left, pressed: true));
    events.add(
      const DesktopShiftEvent(key: PhysicalShift.right, pressed: true),
    );
    events.add(const DesktopSecureInputEvent(true));
    events.add(
      const DesktopShiftEvent(key: PhysicalShift.left, pressed: false),
    );
    events.add(
      const DesktopShiftEvent(key: PhysicalShift.right, pressed: false),
    );
    await Future<void>.delayed(Duration.zero);

    expect(actions, [ShiftGestureAction.cancel]);
    await subscription.cancel();
    await controller.dispose();
    await events.close();
  });
}
