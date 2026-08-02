import 'package:flutter_test/flutter_test.dart';
import 'package:omi/keyboard/keyboard.dart';

void main() {
  var now = DateTime.utc(2026, 7, 22);
  DateTime clock() => now;
  void advance(Duration duration) => now = now.add(duration);

  ShiftGestureMachine machine() {
    now = DateTime.utc(2026, 7, 22);
    return ShiftGestureMachine(now: clock);
  }

  List<ShiftGestureAction> chord(ShiftGestureMachine gesture) {
    final actions = [
      ...gesture.shift(PhysicalShift.left, true),
      ...gesture.shift(PhysicalShift.right, true),
      ...gesture.shift(PhysicalShift.left, false),
      ...gesture.shift(PhysicalShift.right, false),
    ];
    return actions;
  }

  test('a single chord resolves to the text input after the window', () {
    final gesture = machine();

    expect(chord(gesture), isEmpty);
    expect(gesture.hasPendingChord, isTrue);
    advance(const Duration(milliseconds: 400));
    expect(gesture.chordTimeout(), [ShiftGestureAction.openOverlay]);
    expect(gesture.hasPendingChord, isFalse);
    // The timeout only fires once.
    expect(gesture.chordTimeout(), isEmpty);
  });

  test('two chords inside the window toggle voice', () {
    final gesture = machine();

    expect(chord(gesture), isEmpty);
    advance(const Duration(milliseconds: 250));
    expect(chord(gesture), [ShiftGestureAction.toggleVoice]);
    expect(gesture.hasPendingChord, isFalse);
    // The stale timer resolves to nothing after the upgrade.
    advance(const Duration(milliseconds: 400));
    expect(gesture.chordTimeout(), isEmpty);
  });

  test('two chords farther apart than the window are two single chords', () {
    final gesture = machine();

    expect(chord(gesture), isEmpty);
    advance(const Duration(milliseconds: 401));
    expect(gesture.chordTimeout(), [ShiftGestureAction.openOverlay]);
    expect(chord(gesture), isEmpty);
    advance(const Duration(milliseconds: 400));
    expect(gesture.chordTimeout(), [ShiftGestureAction.openOverlay]);
  });

  test('holding the chord does not re-fire', () {
    final gesture = machine();

    expect(gesture.shift(PhysicalShift.left, true), isEmpty);
    expect(gesture.shift(PhysicalShift.right, true), isEmpty);
    expect(gesture.shift(PhysicalShift.left, true), isEmpty);
    expect(gesture.hasPendingChord, isTrue);
  });

  test('a single Shift never activates the gesture', () {
    final gesture = machine();

    expect(gesture.shift(PhysicalShift.left, true), isEmpty);
    expect(gesture.shift(PhysicalShift.left, false), isEmpty);
    expect(gesture.hasPendingChord, isFalse);
  });

  test('escape always emits the shared dismissal and clears the chord', () {
    final gesture = machine();
    chord(gesture);
    expect(gesture.escape(), [ShiftGestureAction.escape]);
    expect(gesture.hasPendingChord, isFalse);
  });

  test('secure input cancels and suppresses every trigger', () {
    final gesture = machine();

    gesture.shift(PhysicalShift.left, true);
    expect(gesture.setSecureInput(true), [ShiftGestureAction.cancel]);
    expect(gesture.shift(PhysicalShift.left, true), isEmpty);
    expect(gesture.shift(PhysicalShift.right, true), isEmpty);
    expect(gesture.hasPendingChord, isFalse);

    expect(gesture.setSecureInput(false), isEmpty);
    // A partial chord captured under secure input is discarded, so the next
    // press must not spuriously toggle.
    expect(gesture.shift(PhysicalShift.left, true), isEmpty);
    expect(gesture.shift(PhysicalShift.right, true), isEmpty);
    expect(gesture.hasPendingChord, isTrue);
  });

  test('the secure-input state repeated between keys keeps the chord', () {
    final gesture = machine();

    // What the native side actually sends: the current secure-input state
    // ahead of every keystroke.
    List<ShiftGestureAction> press(PhysicalShift key, bool pressed) => [
      ...gesture.setSecureInput(false),
      ...gesture.shift(key, pressed),
    ];

    expect(press(PhysicalShift.left, true), isEmpty);
    expect(press(PhysicalShift.right, true), isEmpty);
    expect(press(PhysicalShift.left, false), isEmpty);
    expect(press(PhysicalShift.right, false), isEmpty);
    expect(gesture.hasPendingChord, isTrue);

    advance(const Duration(milliseconds: 250));
    expect(press(PhysicalShift.left, true), isEmpty);
    expect(press(PhysicalShift.right, true), [ShiftGestureAction.toggleVoice]);
  });

  test('a second chord that keeps one Shift held still toggles voice', () {
    final gesture = machine();

    expect(gesture.shift(PhysicalShift.left, true), isEmpty);
    expect(gesture.shift(PhysicalShift.right, true), isEmpty);
    expect(gesture.hasPendingChord, isTrue);
    // Only the right Shift is tapped again; the left one never comes up.
    expect(gesture.shift(PhysicalShift.right, false), isEmpty);
    advance(const Duration(milliseconds: 200));
    expect(gesture.shift(PhysicalShift.right, true), [
      ShiftGestureAction.toggleVoice,
    ]);
  });

  test('the double-chord window fits an unhurried human repeat', () {
    final gesture = machine();

    expect(chord(gesture), isEmpty);
    advance(const Duration(milliseconds: 450));
    expect(chord(gesture), [ShiftGestureAction.toggleVoice]);
  });

  test('secure input cancels once, not on every repeat', () {
    final gesture = machine();

    expect(gesture.setSecureInput(true), [ShiftGestureAction.cancel]);
    expect(gesture.setSecureInput(true), isEmpty);
    expect(gesture.setSecureInput(false), isEmpty);
    expect(gesture.setSecureInput(true), [ShiftGestureAction.cancel]);
  });
}
