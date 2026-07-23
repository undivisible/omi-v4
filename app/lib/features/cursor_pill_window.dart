import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class CursorPillWindow {
  static const _channel = MethodChannel('omi/window_chrome');
  static const width = 460.0;
  static const height = 320.0;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// Summons the floating glass text-input window next to the cursor. Once
  /// shown it stays put (static, interactive, key) — voice never goes through
  /// this window; its glow and waveform are native surfaces owned by
  /// [VoiceOverlayWindow].
  ///
  /// The window is a separate non-activating NSPanel with its own Flutter
  /// engine (`pillMain`): the main app window never moves, resizes, or
  /// changes level when the pill comes and goes.
  static Future<void> summon() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('summonPill', {
        'width': width,
        'height': height,
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  static Future<void> restore() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('restoreFromPill');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}

/// The native voice surfaces: a separate borderless click-through NSWindow
/// hosting the full-screen edge glow, plus a small follow-cursor waveform
/// panel — both rendered natively in Swift so the main app window never
/// moves or changes while listening.
abstract final class VoiceOverlayWindow {
  static const _channel = MethodChannel('omi/voice_overlay');

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static Future<void> start() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('start');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  static Future<void> stop() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('stop');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  /// Shows the full-screen edge glow on its own, without the waveform, for a
  /// gesture that is not speech — the onboarding shake fills it as the meter
  /// rises.
  static Future<void> startGlow() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('startGlow');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  /// Flares the glow to full and fades it out, resolving once the animation
  /// has finished and the surface is gone.
  static Future<void> burst() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('burst');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  /// Streams the live audio level (0..1) that drives the native glow swell
  /// and waveform bars.
  static Future<void> level(double value) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('level', value);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}
