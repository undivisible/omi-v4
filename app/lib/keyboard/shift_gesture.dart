enum PhysicalShift { left, right }

/// The interaction is now a thin detector: the physical chord (counted once
/// vs twice inside [doubleChordWindow]) emits a single intent, and the surface
/// that consumes them ([CursorPillController]) owns all real state (and the
/// debounce).
///
/// - both Shift keys down once: [openOverlay] — summon the text input next
///   to the cursor, or dismiss whatever surface is already up. The action is
///   held back for [doubleChordWindow] so a second chord can upgrade it.
/// - the chord twice within [doubleChordWindow]: [toggleVoice] — start
///   listening immediately, or dismiss the surface that is up.
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
  ShiftGestureMachine({
    DateTime Function()? now,
    this.doubleChordWindow = const Duration(milliseconds: 400),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// How long a completed chord waits for a second chord before it resolves
  /// as the single-chord text-input intent.
  final Duration doubleChordWindow;

  bool secureInput = false;
  bool _leftDown = false;
  bool _rightDown = false;
  bool _chordConsumed = false;
  DateTime? _pendingChordAt;
  DateTime? _singleShiftTapAt;
  PhysicalShift? _singleShiftTapKey;

  /// True while a first chord is waiting out [doubleChordWindow]; the owner
  /// must schedule [chordTimeout] after that window to resolve it.
  bool get hasPendingChord => _pendingChordAt != null;

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
      _singleShiftTapAt = null;
      _singleShiftTapKey = null;
      final at = _now();
      final pendingAt = _pendingChordAt;
      if (pendingAt != null && at.difference(pendingAt) <= doubleChordWindow) {
        _pendingChordAt = null;
        return const [ShiftGestureAction.toggleVoice];
      }
      _pendingChordAt = at;
      return const [];
    }

    // macOS reports physical Shift transitions through flagsChanged. Supporting
    // two taps of either physical key matches the public "double-Shift" affordance;
    // the existing two-key chord remains available for people who use it.
    if (!pressed && !_leftDown && !_rightDown && !_chordConsumed) {
      final at = _now();
      final priorAt = _singleShiftTapAt;
      if (priorAt != null &&
          _singleShiftTapKey == key &&
          at.difference(priorAt) <= doubleChordWindow) {
        _singleShiftTapAt = null;
        _singleShiftTapKey = null;
        return const [ShiftGestureAction.toggleVoice];
      }
      _singleShiftTapAt = at;
      _singleShiftTapKey = key;
    }

    _clearChordWhenReleased();
    return const [];
  }

  /// Resolves a first chord whose [doubleChordWindow] elapsed with no second
  /// chord: it was a single chord, which summons the text input. The owner's
  /// timer is the clock — a pending chord resolves unconditionally, and a
  /// chord upgraded to voice already cleared the pending state.
  List<ShiftGestureAction> chordTimeout() {
    if (_pendingChordAt == null) return const [];
    _pendingChordAt = null;
    return const [ShiftGestureAction.openOverlay];
  }

  List<ShiftGestureAction> escape() {
    _reset();
    return const [ShiftGestureAction.escape];
  }

  void reset() => _reset();

  void _clearChordWhenReleased() {
    if (!_leftDown && !_rightDown) _chordConsumed = false;
  }

  void _reset() {
    _leftDown = false;
    _rightDown = false;
    _chordConsumed = false;
    _pendingChordAt = null;
    _singleShiftTapAt = null;
    _singleShiftTapKey = null;
  }
}
