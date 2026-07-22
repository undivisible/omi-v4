import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class CursorPillWindow {
  static const _channel = MethodChannel('omi/window_chrome');
  static const width = 420.0;
  static const height = 230.0;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

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
