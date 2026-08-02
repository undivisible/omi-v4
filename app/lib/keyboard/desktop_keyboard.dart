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

/// Ignored — cursor-shake summon was removed; kept so older native builds
/// do not crash the decoder.
final class DesktopShakeEvent extends DesktopKeyboardEvent {
  const DesktopShakeEvent();
}

/// Emitted once at stream start when global capture cannot run while another
/// app is frontmost — the double-Shift chord still works inside Omi via the
/// local keyboard monitor, but system-wide shortcuts need Input Monitoring.
final class DesktopGlobalHotkeyUnavailableEvent extends DesktopKeyboardEvent {
  const DesktopGlobalHotkeyUnavailableEvent({
    this.trusted = false,
    this.inputMonitoring = false,
  });

  final bool trusted;
  final bool inputMonitoring;
}

/// Whether omi itself is the frontmost application. The chord means two
/// different things either side of this line: in-app it focuses the hub's
/// own input, in the background it summons the floating pill panel.
final class DesktopAppActivationEvent extends DesktopKeyboardEvent {
  const DesktopAppActivationEvent(this.active);

  final bool active;
}

/// The live state of global input capture: whether the process is
/// Accessibility-trusted, whether it holds Input Monitoring (required for the
/// session keyboard event tap), whether that tap is actually installed, and
/// whether macOS secure event input is withholding keystrokes from every
/// observer. Surfaced in-app so a missing grant, a dead tap or a suppressed
/// keyboard is visible instead of silent.
final class DesktopInputDiagnosticsEvent extends DesktopKeyboardEvent {
  const DesktopInputDiagnosticsEvent({
    required this.trusted,
    required this.inputMonitoring,
    required this.tapInstalled,
    this.secureInput = false,
  });

  final bool trusted;
  final bool inputMonitoring;
  final bool tapInstalled;
  final bool secureInput;

  /// True when global shortcuts really are being watched right now. Secure
  /// input counts against it: while it is on the tap stays installed but the
  /// system delivers nothing to it, so the chord is just as dead.
  bool get globalCaptureLive => tapInstalled && !secureInput;
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
      // Legacy native builds may still emit this; ignore it.
      'summonOverlay' => const DesktopShakeEvent(),
      'shake' => const DesktopShakeEvent(),
      'globalHotkeyUnavailable' => DesktopGlobalHotkeyUnavailableEvent(
        trusted: raw['trusted'] == true,
        inputMonitoring: raw['inputMonitoring'] == true,
      ),
      'appActivation' => DesktopAppActivationEvent(raw['active'] == true),
      'diagnostics' => DesktopInputDiagnosticsEvent(
        trusted: raw['trusted'] == true,
        inputMonitoring: raw['inputMonitoring'] == true,
        tapInstalled: raw['tapInstalled'] == true,
        secureInput: raw['secureInput'] == true,
      ),
      _ => throw const FormatException('unknown keyboard event'),
    };
  }
}
