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
      DesktopSecureInputEvent(:final enabled) => _machine.setSecureInput(
        enabled,
      ),
      DesktopEscapeEvent() => _machine.escape(),
      DesktopGlobalHotkeyUnavailableEvent() => const <ShiftGestureAction>[],
    };
    _emit(actions);
  }

  void _emit(List<ShiftGestureAction> actions) {
    for (final action in actions) {
      _actions.add(action);
    }
  }

  void reset() => _machine.reset();

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _actions.close();
  }
}
