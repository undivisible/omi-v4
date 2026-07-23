import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const backgroundCaptureChannelName = 'omi/background_capture';

/// What backgrounding actually buys on this platform.
enum BackgroundCaptureSupport {
  /// The process is held alive by a user-visible foreground service (Android).
  foregroundService,

  /// The OS resumes the app for BLE notifications, but the process is not
  /// pinned and can be reclaimed (iOS).
  bluetoothWake,

  /// Not a mobile capture platform.
  unsupported,
}

/// Keeps pendant capture running while the app is not on screen.
///
/// **Android.** Starting capture starts a `connectedDevice` foreground service
/// with an ongoing notification. While it runs the process is not eligible for
/// background-process reclaim, so BLE notifications, the Rust hub, the STT
/// socket and the write-ahead log all keep running exactly as they do in the
/// foreground. What still does *not* survive: the user swiping the task away
/// (Android stops the service and the process with it), the user revoking the
/// notification permission on Android 13+ (the service can no longer be
/// started), aggressive OEM battery managers that kill even foreground
/// services, and device reboot — nothing here re-launches the app.
///
/// **iOS.** There is no foreground service and no equivalent. The app declares
/// `UIBackgroundModes: bluetooth-central`, which means iOS wakes the suspended
/// app to deliver BLE notifications from an already-connected peripheral, and
/// that wake is short. In practice pendant frames keep arriving and keep being
/// written to the write-ahead log, but the following do *not* survive
/// backgrounding on iOS and are not claimed to: the long-lived STT WebSocket
/// (the system tears down sockets on a suspended app, so live transcription
/// stops and audio falls back to the log), wall-clock timers such as the WAL
/// upload pump and the memory sync pump, and the process itself under memory
/// pressure — with no CoreBluetooth state-restoration identifier there is
/// nothing that relaunches the app, so a jetsam kill or a force-quit ends
/// capture until the user reopens Omi. Backgrounded iOS capture is
/// *durability*, not *live transcription*.
final class BackgroundCaptureController {
  BackgroundCaptureController({
    MethodChannel? channel,
    TargetPlatform? platform,
  }) : _channel = channel ?? const MethodChannel(backgroundCaptureChannelName),
       _platform = platform ?? (kIsWeb ? null : defaultTargetPlatform);

  final MethodChannel _channel;
  final TargetPlatform? _platform;

  bool _running = false;

  bool get running => _running;

  BackgroundCaptureSupport get support => switch (_platform) {
    TargetPlatform.android => BackgroundCaptureSupport.foregroundService,
    TargetPlatform.iOS => BackgroundCaptureSupport.bluetoothWake,
    _ => BackgroundCaptureSupport.unsupported,
  };

  /// Starts holding the process. Returns false when the platform has nothing
  /// to hold (iOS, desktop) or the platform refused.
  Future<bool> start({String? deviceName}) async {
    if (support != BackgroundCaptureSupport.foregroundService) return false;
    try {
      final started = await _channel.invokeMethod<bool>('start', {
        'deviceName': deviceName ?? 'Omi',
      });
      _running = started ?? false;
    } on PlatformException {
      _running = false;
    } on MissingPluginException {
      _running = false;
    }
    return _running;
  }

  Future<void> stop() async {
    if (support != BackgroundCaptureSupport.foregroundService) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Stopping a service that is already gone is not an error worth raising.
    } on MissingPluginException {
      // No Android host on this build; there was nothing to stop.
    }
    _running = false;
  }
}
