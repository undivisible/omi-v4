import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _captureNotificationChannelId = 'omi_capture';
const _captureNotificationChannelName = 'Capture';
const _captureNotificationChannelDescription =
    'Shown while your Omi pendant is streaming audio to this phone.';

/// Capture is visible in Notification Center without interrupting the screen
/// the user is already looking at. A foreground iOS alert applies a system blur
/// to the app beneath it, so it is deliberately disabled here.
NotificationDetails captureNotificationDetails() => const NotificationDetails(
  android: AndroidNotificationDetails(
    _captureNotificationChannelId,
    _captureNotificationChannelName,
    channelDescription: _captureNotificationChannelDescription,
    importance: Importance.low,
    priority: Priority.low,
    ongoing: true,
    playSound: false,
    enableVibration: false,
  ),
  iOS: DarwinNotificationDetails(
    presentAlert: false,
    presentBadge: false,
    presentSound: false,
  ),
);

/// Posts the ambient "Omi is listening" phone notification raised when the
/// user starts a capture from the pendant hero. Kept behind an interface so
/// widget tests can observe the call without touching platform channels.
abstract interface class CaptureNotifier {
  Future<void> captureStarted({required String deviceName});

  Future<void> captureStopped();
}

/// Used in the interface preview and on platforms without a notification
/// surface: every call is a silent no-op.
final class NoopCaptureNotifier implements CaptureNotifier {
  const NoopCaptureNotifier();

  @override
  Future<void> captureStarted({required String deviceName}) async {}

  @override
  Future<void> captureStopped() async {}
}

/// Local (on-device) notification backed by flutter_local_notifications. The
/// plugin only ships a notification surface on iOS and Android, so every other
/// platform degrades to a no-op instead of throwing at initialize() time.
final class LocalCaptureNotifier implements CaptureNotifier {
  LocalCaptureNotifier({
    FlutterLocalNotificationsPlugin? plugin,
    TargetPlatform? platform,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _platform = platform ?? defaultTargetPlatform;

  static const _notificationId = 0xa11;

  final FlutterLocalNotificationsPlugin _plugin;
  final TargetPlatform _platform;
  Future<bool>? _ready;

  bool get _supported =>
      !kIsWeb &&
      (_platform == TargetPlatform.iOS || _platform == TargetPlatform.android);

  Future<bool> _initialize() async {
    if (!_supported) return false;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: true,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      if (_platform == TargetPlatform.android) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> captureStarted({required String deviceName}) async {
    if (!await (_ready ??= _initialize())) return;
    try {
      await _plugin.show(
        id: _notificationId,
        title: 'Omi is listening',
        body: '$deviceName is streaming audio to this phone.',
        notificationDetails: captureNotificationDetails(),
      );
    } catch (_) {}
  }

  @override
  Future<void> captureStopped() async {
    if (!_supported || _ready == null) return;
    if (!await _ready!) return;
    try {
      await _plugin.cancel(id: _notificationId);
    } catch (_) {}
  }
}
