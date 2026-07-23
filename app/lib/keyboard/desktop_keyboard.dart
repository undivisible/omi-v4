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

/// Whether omi itself is the frontmost application. The chord means two
/// different things either side of this line: in-app it focuses the hub's
/// own input, in the background it summons the floating pill panel.
final class DesktopAppActivationEvent extends DesktopKeyboardEvent {
  const DesktopAppActivationEvent(this.active);

  final bool active;
}

/// The live state of global input capture: whether the process is
/// Accessibility-trusted, and whether the session event tap that watches the
/// chord and the pointer shake is actually installed. Surfaced in-app so a
/// missing grant or a dead tap is visible instead of silent.
final class DesktopInputDiagnosticsEvent extends DesktopKeyboardEvent {
  const DesktopInputDiagnosticsEvent({
    required this.trusted,
    required this.tapInstalled,
  });

  final bool trusted;
  final bool tapInstalled;

  /// True when global shortcuts really are being watched right now.
  bool get globalCaptureLive => trusted && tapInstalled;
}

final class DesktopKeyboard {
  DesktopKeyboard({EventChannel? channel, MethodChannel? control})
    : _channel = channel ?? const EventChannel('omi/desktop_keyboard'),
      _control = control ?? const MethodChannel('omi/desktop_keyboard_control');

  final EventChannel _channel;
  final MethodChannel _control;
  Stream<DesktopKeyboardEvent>? _events;

  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  /// One shared stream per instance. Every `receiveBroadcastStream()` call
  /// installs its own handler for the channel name, and the newest one
  /// replaces the last — so subscribing twice (gestures and the in-app
  /// notices) would silently starve the first subscriber of every event.
  Stream<DesktopKeyboardEvent> get events {
    if (!supported) return const Stream.empty();
    return _events ??= _channel
        .receiveBroadcastStream()
        .map(_decode)
        .asBroadcastStream();
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
      'appActivation' => DesktopAppActivationEvent(raw['active'] == true),
      'diagnostics' => DesktopInputDiagnosticsEvent(
        trusted: raw['trusted'] == true,
        tapInstalled: raw['tapInstalled'] == true,
      ),
      _ => throw const FormatException('unknown keyboard event'),
    };
  }
}
