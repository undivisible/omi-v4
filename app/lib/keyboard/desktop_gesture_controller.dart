import 'dart:async';

import 'desktop_keyboard.dart';
import 'shift_gesture.dart';

final class DesktopGestureController {
  DesktopGestureController({
    DesktopKeyboard? keyboard,
    Stream<DesktopKeyboardEvent>? events,
    ShiftGestureMachine? machine,
    DateTime Function()? now,
  }) : _events = events ?? (keyboard ?? DesktopKeyboard()).events,
       _machine = machine ?? ShiftGestureMachine(),
       _now = now ?? DateTime.now;

  final Stream<DesktopKeyboardEvent> _events;
  final ShiftGestureMachine _machine;
  final DateTime Function() _now;
  final _actions = StreamController<ShiftGestureAction>.broadcast(sync: true);
  StreamSubscription<DesktopKeyboardEvent>? _subscription;
  Timer? _holdTimer;

  Stream<ShiftGestureAction> get actions => _actions.stream;

  void start() {
    _subscription ??= _events.listen(_handleEvent);
  }

  void _handleEvent(DesktopKeyboardEvent event) {
    final actions = switch (event) {
      DesktopShiftEvent(:final key, :final pressed) => _machine.shift(
        key,
        pressed,
        _time,
      ),
      DesktopSecureInputEvent(:final enabled) => _machine.setSecureInput(
        enabled,
      ),
      DesktopEscapeEvent() => _machine.escape(),
    };
    if (_machine.phase == ShiftGesturePhase.chordPending) {
      _holdTimer ??= Timer(_machine.holdThreshold, () {
        _holdTimer = null;
        _emit(_machine.advance(_time));
      });
    } else {
      _holdTimer?.cancel();
      _holdTimer = null;
    }
    _emit(actions);
  }

  Duration get _time => Duration(milliseconds: _now().millisecondsSinceEpoch);

  void _emit(List<ShiftGestureAction> actions) {
    for (final action in actions) {
      _actions.add(action);
    }
  }

  void reset() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _machine.reset();
  }

  Future<void> dispose() async {
    _holdTimer?.cancel();
    await _subscription?.cancel();
    await _actions.close();
  }
}
