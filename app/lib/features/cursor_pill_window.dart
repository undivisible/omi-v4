import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class CursorPillWindow {
  static const _channel = MethodChannel('omi/window_chrome');
  static const width = 420.0;
  static const height = 230.0;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// Summons the floating glass window. Voice (the waveform) rides the cursor
  /// ([centered] false); the text overlay is a Spotlight-style panel pinned to
  /// the upper third of the screen ([centered] true).
  static Future<void> summon({bool centered = false}) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('summonPill', {
        'width': width,
        'height': height,
        'centered': centered,
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  /// Reports the pill's rounded-rect glass regions (logical points,
  /// top-left origin) so the native Liquid Glass layer under the Flutter
  /// view can mask itself to match.
  static Future<void> updateGlass(
    List<({double x, double y, double w, double h, double r})> regions, {
    double radius = 18,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('updatePillGlass', {
        'regions': [
          for (final region in regions)
            {
              'x': region.x,
              'y': region.y,
              'w': region.w,
              'h': region.h,
              'r': region.r,
            },
        ],
        'radius': radius,
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
