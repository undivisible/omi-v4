import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'shift_gesture.dart';

/// Human-readable label for the global keybind that summons the centered
/// text overlay. The actual key detection lives natively
/// (`MainFlutterWindow.swift`, `summonOverlayKeyCode`); this constant is the
/// single place the shortcut is named so it can be surfaced in UI/onboarding
/// and later made configurable.
const summonOverlayKeybindLabel = 'Option + Space';

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

/// The global overlay keybind ([summonOverlayKeybindLabel], Option+Space by
/// default) fired system-wide from the native keyboard monitor.
final class DesktopSummonOverlayEvent extends DesktopKeyboardEvent {
  const DesktopSummonOverlayEvent();
}

/// A completed cursor shake detected by the native global mouse monitor
/// (rapid direction reversals filling the shake meter) — "talk to the
/// agent", equivalent to the double chord.
final class DesktopShakeEvent extends DesktopKeyboardEvent {
  const DesktopShakeEvent();
}

/// Emitted once at stream start when the process lacks the Accessibility
/// grant, meaning the global keyboard monitor cannot see keystrokes while
/// another app is frontmost — the chord and overlay keybind only work
/// inside omi until the grant is made.
final class DesktopGlobalHotkeyUnavailableEvent extends DesktopKeyboardEvent {
  const DesktopGlobalHotkeyUnavailableEvent();
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
      'summonOverlay' => const DesktopSummonOverlayEvent(),
      'shake' => const DesktopShakeEvent(),
      'globalHotkeyUnavailable' => const DesktopGlobalHotkeyUnavailableEvent(),
      _ => throw const FormatException('unknown keyboard event'),
    };
  }
}
