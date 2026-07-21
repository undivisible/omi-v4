import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'shift_gesture.dart';

sealed class DesktopKeyboardEvent {
  const DesktopKeyboardEvent();
}

final class DesktopShiftEvent extends DesktopKeyboardEvent {
  const DesktopShiftEvent({required this.key, required this.pressed});

  final PhysicalShift key;
  final bool pressed;
}

final class DesktopSecureInputEvent extends DesktopKeyboardEvent {
  const DesktopSecureInputEvent(this.enabled);

  final bool enabled;
}

final class DesktopEscapeEvent extends DesktopKeyboardEvent {
  const DesktopEscapeEvent();
}

final class DesktopKeyboard {
  DesktopKeyboard({EventChannel? channel, MethodChannel? control})
    : _channel = channel ?? const EventChannel('omi/desktop_keyboard'),
      _control = control ?? const MethodChannel('omi/desktop_keyboard_control');

  final EventChannel _channel;
  final MethodChannel _control;

  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  Stream<DesktopKeyboardEvent> get events {
    if (!supported) return const Stream.empty();
    return _channel.receiveBroadcastStream().map(_decode);
  }

  Future<void> focusApplication() async {
    if (supported) await _control.invokeMethod<void>('focus');
  }

  DesktopKeyboardEvent _decode(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('keyboard event must be a map');
    }
    return switch (raw['type']) {
      'shift' => DesktopShiftEvent(
        key: switch (raw['key']) {
          'left' => PhysicalShift.left,
          'right' => PhysicalShift.right,
          _ => throw const FormatException('unknown physical shift key'),
        },
        pressed: raw['pressed'] == true,
      ),
      'secureInput' => DesktopSecureInputEvent(raw['enabled'] == true),
      'escape' => const DesktopEscapeEvent(),
      _ => throw const FormatException('unknown keyboard event'),
    };
  }
}
