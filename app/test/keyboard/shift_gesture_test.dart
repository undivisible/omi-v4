import 'package:flutter_test/flutter_test.dart';
import 'package:omi/keyboard/keyboard.dart';

void main() {
  const zero = Duration.zero;

  test('quick chord opens text input and the next chord submits', () {
    final gesture = ShiftGestureMachine();

    gesture.shift(PhysicalShift.left, true, zero);
    gesture.shift(PhysicalShift.right, true, const Duration(milliseconds: 20));
    expect(
      gesture.shift(
        PhysicalShift.left,
        false,
        const Duration(milliseconds: 100),
      ),
      [ShiftGestureAction.openTextInput],
    );
    gesture.shift(
      PhysicalShift.right,
      false,
      const Duration(milliseconds: 110),
    );

    gesture.shift(PhysicalShift.left, true, const Duration(milliseconds: 200));
    expect(
      gesture.shift(
        PhysicalShift.right,
        true,
        const Duration(milliseconds: 210),
      ),
      [ShiftGestureAction.submitText],
    );
    expect(gesture.phase, ShiftGesturePhase.idle);
  });

  test('held chord starts voice and release continues hands free', () {
    final gesture = ShiftGestureMachine(
      holdThreshold: const Duration(milliseconds: 300),
    );

    gesture.shift(PhysicalShift.left, true, zero);
    gesture.shift(PhysicalShift.right, true, const Duration(milliseconds: 10));
    expect(gesture.advance(const Duration(milliseconds: 309)), isEmpty);
    expect(gesture.advance(const Duration(milliseconds: 310)), [
      ShiftGestureAction.startVoice,
    ]);
    expect(gesture.phase, ShiftGesturePhase.pushToTalk);
    expect(
      gesture.shift(
        PhysicalShift.left,
        false,
        const Duration(milliseconds: 400),
      ),
      [ShiftGestureAction.continueVoice],
    );
    expect(gesture.phase, ShiftGesturePhase.handsFree);
  });

  test('release after threshold is voice even without an advance tick', () {
    final gesture = ShiftGestureMachine(
      holdThreshold: const Duration(milliseconds: 300),
    );

    gesture.shift(PhysicalShift.left, true, zero);
    gesture.shift(PhysicalShift.right, true, const Duration(milliseconds: 10));
    expect(
      gesture.shift(
        PhysicalShift.right,
        false,
        const Duration(milliseconds: 310),
      ),
      [ShiftGestureAction.startVoice, ShiftGestureAction.continueVoice],
    );
    expect(gesture.phase, ShiftGesturePhase.handsFree);
  });

  test('next chord stops hands-free voice', () {
    final gesture = ShiftGestureMachine();

    gesture.shift(PhysicalShift.left, true, zero);
    gesture.shift(PhysicalShift.right, true, zero);
    gesture.advance(const Duration(milliseconds: 350));
    gesture.shift(PhysicalShift.left, false, const Duration(milliseconds: 360));
    gesture.shift(
      PhysicalShift.right,
      false,
      const Duration(milliseconds: 370),
    );
    gesture.shift(PhysicalShift.left, true, const Duration(milliseconds: 400));
    expect(
      gesture.shift(
        PhysicalShift.right,
        true,
        const Duration(milliseconds: 410),
      ),
      [ShiftGestureAction.stopVoice],
    );
  });

  test('escape cancels pending and active gestures', () {
    final gesture = ShiftGestureMachine();

    gesture.shift(PhysicalShift.left, true, zero);
    gesture.shift(PhysicalShift.right, true, zero);
    expect(gesture.escape(), [ShiftGestureAction.cancel]);
    expect(gesture.phase, ShiftGesturePhase.idle);
    expect(gesture.escape(), isEmpty);
  });

  test('secure input cancels active gestures and ignores shifts', () {
    final gesture = ShiftGestureMachine();

    gesture.shift(PhysicalShift.left, true, zero);
    gesture.shift(PhysicalShift.right, true, zero);
    gesture.shift(PhysicalShift.left, false, const Duration(milliseconds: 50));
    expect(gesture.phase, ShiftGesturePhase.textInput);
    expect(gesture.setSecureInput(true), [ShiftGestureAction.cancel]);
    expect(
      gesture.shift(
        PhysicalShift.left,
        true,
        const Duration(milliseconds: 100),
      ),
      isEmpty,
    );
    expect(
      gesture.shift(
        PhysicalShift.right,
        true,
        const Duration(milliseconds: 100),
      ),
      isEmpty,
    );
    expect(gesture.phase, ShiftGesturePhase.idle);
  });

  test('a single shift never activates the gesture', () {
    final gesture = ShiftGestureMachine();

    expect(gesture.shift(PhysicalShift.left, true, zero), isEmpty);
    expect(gesture.advance(const Duration(seconds: 1)), isEmpty);
    expect(
      gesture.shift(PhysicalShift.left, false, const Duration(seconds: 2)),
      isEmpty,
    );
    expect(gesture.phase, ShiftGesturePhase.idle);
  });
}
