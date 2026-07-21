enum PhysicalShift { left, right }

enum ShiftGesturePhase { idle, chordPending, textInput, pushToTalk, handsFree }

enum ShiftGestureAction {
  openTextInput,
  submitText,
  startVoice,
  continueVoice,
  stopVoice,
  cancel,
}

class ShiftGestureMachine {
  ShiftGestureMachine({this.holdThreshold = const Duration(milliseconds: 350)});

  final Duration holdThreshold;

  ShiftGesturePhase phase = ShiftGesturePhase.idle;
  bool secureInput = false;
  bool _leftDown = false;
  bool _rightDown = false;
  Duration? _chordStartedAt;
  bool _chordConsumed = false;

  List<ShiftGestureAction> setSecureInput(bool enabled) {
    secureInput = enabled;
    if (!enabled || phase == ShiftGesturePhase.idle) return const [];
    _reset();
    return const [ShiftGestureAction.cancel];
  }

  List<ShiftGestureAction> shift(PhysicalShift key, bool pressed, Duration at) {
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
      if (phase == ShiftGesturePhase.textInput) {
        _reset(keepKeys: true);
        return const [ShiftGestureAction.submitText];
      }
      if (phase == ShiftGesturePhase.handsFree) {
        _reset(keepKeys: true);
        return const [ShiftGestureAction.stopVoice];
      }
      if (phase == ShiftGesturePhase.idle) {
        phase = ShiftGesturePhase.chordPending;
        _chordStartedAt = at;
      }
    }

    if (!bothDown &&
        phase == ShiftGesturePhase.chordPending &&
        _chordStartedAt != null) {
      if (at - _chordStartedAt! >= holdThreshold) {
        phase = ShiftGesturePhase.handsFree;
        _clearChordWhenReleased();
        return const [
          ShiftGestureAction.startVoice,
          ShiftGestureAction.continueVoice,
        ];
      }
      phase = ShiftGesturePhase.textInput;
      _chordStartedAt = null;
      _clearChordWhenReleased();
      return const [ShiftGestureAction.openTextInput];
    }

    if (!bothDown && phase == ShiftGesturePhase.pushToTalk) {
      phase = ShiftGesturePhase.handsFree;
      _clearChordWhenReleased();
      return const [ShiftGestureAction.continueVoice];
    }

    _clearChordWhenReleased();
    return const [];
  }

  List<ShiftGestureAction> advance(Duration at) {
    if (secureInput ||
        phase != ShiftGesturePhase.chordPending ||
        _chordStartedAt == null) {
      return const [];
    }
    if (at - _chordStartedAt! < holdThreshold) {
      return const [];
    }
    phase = ShiftGesturePhase.pushToTalk;
    return const [ShiftGestureAction.startVoice];
  }

  List<ShiftGestureAction> stop() {
    if (phase == ShiftGesturePhase.textInput) {
      _reset();
      return const [ShiftGestureAction.submitText];
    }
    if (phase == ShiftGesturePhase.pushToTalk ||
        phase == ShiftGesturePhase.handsFree) {
      _reset();
      return const [ShiftGestureAction.stopVoice];
    }
    return const [];
  }

  List<ShiftGestureAction> escape() {
    if (phase == ShiftGesturePhase.idle) return const [];
    _reset();
    return const [ShiftGestureAction.cancel];
  }

  void _clearChordWhenReleased() {
    if (!_leftDown && !_rightDown) _chordConsumed = false;
  }

  void _reset({bool keepKeys = false}) {
    phase = ShiftGesturePhase.idle;
    _chordStartedAt = null;
    if (!keepKeys) {
      _leftDown = false;
      _rightDown = false;
      _chordConsumed = false;
    }
  }
}
