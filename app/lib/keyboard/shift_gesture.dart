enum PhysicalShift { left, right }

/// The interaction is now a thin detector: the physical chord and the
/// overlay keybind each emit a single intent, and the surface that consumes
/// them ([CursorPillController]) owns all real state (and the debounce).
///
/// - both Shift keys down: [toggleVoice] — start listening immediately, or
///   dismiss whatever surface is already up (voice or overlay).
/// - the overlay keybind (Option+Space): [openOverlay] — summon the centered
///   text overlay, or dismiss the surface that is up.
/// - Esc: [escape] — dismiss whatever surface is up, identical to a second
///   double-shift.
/// - explicit [startVoice]/[stopVoice] drive the menu-bar controls.
/// - secure-input emits [cancel].
enum ShiftGestureAction {
  toggleVoice,
  openOverlay,
  escape,
  startVoice,
  stopVoice,
  cancel,
}

class ShiftGestureMachine {
  ShiftGestureMachine();

  bool secureInput = false;
  bool _leftDown = false;
  bool _rightDown = false;
  bool _chordConsumed = false;

  List<ShiftGestureAction> setSecureInput(bool enabled) {
    secureInput = enabled;
    // Reset on both edges: entering secure input must not leave voice
    // running, and leaving it must not fire a chord from flags that were
    // still being tracked while suppressed.
    _reset();
    // The surface no-ops if nothing is active, so cancelling unconditionally
    // when secure input engages is safe.
    return enabled ? const [ShiftGestureAction.cancel] : const [];
  }

  List<ShiftGestureAction> shift(PhysicalShift key, bool pressed) {
    if (key == PhysicalShift.left) {
      _leftDown = pressed;
    } else {
      _rightDown = pressed;
    }

    if (secureInput) {
      _clearChordWhenReleased();
      return const [];
    }

    final bothDown = _leftDown && _rightDown;
    if (bothDown && !_chordConsumed) {
      _chordConsumed = true;
      return const [ShiftGestureAction.toggleVoice];
    }

    _clearChordWhenReleased();
    return const [];
  }

  List<ShiftGestureAction> summonOverlay() =>
      secureInput ? const [] : const [ShiftGestureAction.openOverlay];

  List<ShiftGestureAction> escape() => const [ShiftGestureAction.escape];

  void reset() => _reset();

  void _clearChordWhenReleased() {
    if (!_leftDown && !_rightDown) _chordConsumed = false;
  }

  void _reset() {
    _leftDown = false;
    _rightDown = false;
    _chordConsumed = false;
  }
}
