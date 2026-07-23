import 'dart:async';

import 'desktop_keyboard.dart';
import 'shift_gesture.dart';

final class DesktopGestureController {
  DesktopGestureController({
    DesktopKeyboard? keyboard,
    Stream<DesktopKeyboardEvent>? events,
    ShiftGestureMachine? machine,
  }) : _events = events ?? (keyboard ?? DesktopKeyboard()).events,
       _machine = machine ?? ShiftGestureMachine();

  final Stream<DesktopKeyboardEvent> _events;
  final ShiftGestureMachine _machine;
  final _actions = StreamController<ShiftGestureAction>.broadcast(sync: true);
  StreamSubscription<DesktopKeyboardEvent>? _subscription;
  Timer? _chordTimer;

  Stream<ShiftGestureAction> get actions => _actions.stream;

  void start() {
    _subscription ??= _events.listen(_handleEvent);
  }

  void _handleEvent(DesktopKeyboardEvent event) {
    final actions = switch (event) {
      DesktopShiftEvent(:final key, :final pressed) => _machine.shift(
        key,
        pressed,
      ),
      DesktopSummonOverlayEvent() => _machine.summonOverlay(),
      DesktopShakeEvent() => _machine.mouseShake(),
      DesktopSecureInputEvent(:final enabled) => _machine.setSecureInput(
        enabled,
      ),
      DesktopEscapeEvent() => _machine.escape(),
      DesktopGlobalHotkeyUnavailableEvent() => const <ShiftGestureAction>[],
    };
    _emit(actions);
    _armChordTimer();
  }

  /// A first chord is held back for the double-chord window; when no second
  /// chord upgrades it to voice, the timer resolves it as the single-chord
  /// text-input intent.
  void _armChordTimer() {
    _chordTimer?.cancel();
    _chordTimer = null;
    if (!_machine.hasPendingChord) return;
    _chordTimer = Timer(
      _machine.doubleChordWindow,
      () => _emit(_machine.chordTimeout()),
    );
  }

  void _emit(List<ShiftGestureAction> actions) {
    for (final action in actions) {
      _actions.add(action);
    }
  }

  void reset() => _machine.reset();

  Future<void> dispose() async {
    _chordTimer?.cancel();
    await _subscription?.cancel();
    await _actions.close();
  }
}
