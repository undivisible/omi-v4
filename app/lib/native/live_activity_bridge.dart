import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges pendant connection state to an iOS 16.1+ Live Activity /
/// Dynamic Island presence.
///
/// SCAFFOLDING NOTICE: this bridge's Dart-side plumbing is real and safe to
/// call from anywhere the app tracks [DeviceRelaySnapshot]s, but there is
/// currently no native counterpart registered on the iOS side — no
/// `OmiWidgets` WidgetKit extension target exists yet in ios/Runner (adding
/// a new Xcode target is a manual step; see docs/live-activities.md). Until
/// that target and its `omi/live_activity` method channel handler are
/// added, every call here is a safe no-op: `MissingPluginException` is
/// caught and swallowed so the rest of the app is unaffected.
///
/// The corresponding Swift `ActivityAttributes` struct that the widget
/// extension should adopt is scaffolded at
/// ios/Runner/LiveActivityAttributes.swift.
class LiveActivityBridge {
  LiveActivityBridge({MethodChannel? channel, bool? available})
    : _channel = channel ?? const MethodChannel('omi/live_activity'),
      _available =
          available ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  final MethodChannel _channel;
  final bool _available;

  bool _started = false;

  /// Whether Live Activities are supported on this platform at all. This
  /// does NOT mean the native widget extension is registered yet — see the
  /// class doc.
  bool get platformSupported => _available;

  /// Starts (or updates, if already started) the pendant Live Activity.
  ///
  /// [connected] / [batteryLevel] / [deviceName] / [listening] mirror the
  /// current [DeviceRelaySnapshot]. Safe to call on every snapshot change;
  /// no-ops safely if the native side isn't registered.
  Future<void> start({
    required bool connected,
    int? batteryLevel,
    String? deviceName,
    bool listening = false,
  }) async {
    if (!_available) return;
    try {
      await _channel.invokeMethod<void>('start', {
        'connected': connected,
        'batteryLevel': batteryLevel,
        'deviceName': deviceName ?? 'Omi',
        'listening': listening,
      });
      _started = true;
    } on MissingPluginException {
      // No native OmiWidgets extension registered yet. See class doc.
    } catch (_) {
      // Best-effort: Live Activities are a nice-to-have, never fatal.
    }
  }

  Future<void> update({
    required bool connected,
    int? batteryLevel,
    String? deviceName,
    bool listening = false,
  }) async {
    if (!_available) return;
    if (!_started) {
      return start(
        connected: connected,
        batteryLevel: batteryLevel,
        deviceName: deviceName,
        listening: listening,
      );
    }
    try {
      await _channel.invokeMethod<void>('update', {
        'connected': connected,
        'batteryLevel': batteryLevel,
        'deviceName': deviceName ?? 'Omi',
        'listening': listening,
      });
    } on MissingPluginException {
      // No native OmiWidgets extension registered yet. See class doc.
    } catch (_) {}
  }

  Future<void> end() async {
    if (!_available || !_started) return;
    try {
      await _channel.invokeMethod<void>('end');
    } on MissingPluginException {
      // No native OmiWidgets extension registered yet. See class doc.
    } catch (_) {
    } finally {
      _started = false;
    }
  }
}
