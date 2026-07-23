import 'package:flutter_test/flutter_test.dart';
import 'package:omi/keyboard/keyboard.dart';

void main() {
  test('both Shift keys emit a single voice toggle', () {
    final gesture = ShiftGestureMachine();

    expect(gesture.shift(PhysicalShift.left, true), isEmpty);
    expect(gesture.shift(PhysicalShift.right, true), [
      ShiftGestureAction.toggleVoice,
    ]);
    // Holding the chord does not re-fire.
    expect(gesture.shift(PhysicalShift.left, true), isEmpty);
  });

  test('a fresh chord after release toggles again', () {
    final gesture = ShiftGestureMachine();

    gesture.shift(PhysicalShift.left, true);
    expect(gesture.shift(PhysicalShift.right, true), [
      ShiftGestureAction.toggleVoice,
    ]);
    gesture.shift(PhysicalShift.left, false);
    gesture.shift(PhysicalShift.right, false);

    gesture.shift(PhysicalShift.left, true);
    expect(gesture.shift(PhysicalShift.right, true), [
      ShiftGestureAction.toggleVoice,
    ]);
  });

  test('a single Shift never activates the gesture', () {
    final gesture = ShiftGestureMachine();

    expect(gesture.shift(PhysicalShift.left, true), isEmpty);
    expect(gesture.shift(PhysicalShift.left, false), isEmpty);
  });

  test('the overlay keybind emits openOverlay', () {
    final gesture = ShiftGestureMachine();
    expect(gesture.summonOverlay(), [ShiftGestureAction.openOverlay]);
  });

  test('escape always emits the shared dismissal', () {
    final gesture = ShiftGestureMachine();
    expect(gesture.escape(), [ShiftGestureAction.escape]);
  });

  test('secure input cancels and suppresses the chord and the overlay', () {
    final gesture = ShiftGestureMachine();

    gesture.shift(PhysicalShift.left, true);
    expect(gesture.setSecureInput(true), [ShiftGestureAction.cancel]);
    expect(gesture.shift(PhysicalShift.left, true), isEmpty);
    expect(gesture.shift(PhysicalShift.right, true), isEmpty);
    expect(gesture.summonOverlay(), isEmpty);

    expect(gesture.setSecureInput(false), isEmpty);
    // A partial chord captured under secure input is discarded, so the next
    // press must not spuriously toggle.
    expect(gesture.shift(PhysicalShift.left, true), isEmpty);
    expect(gesture.shift(PhysicalShift.right, true), [
      ShiftGestureAction.toggleVoice,
    ]);
  });
}
