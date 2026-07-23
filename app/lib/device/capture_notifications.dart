import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The only two alerts the companion raises.
///
/// This is deliberately not a notification framework. A pendant that has gone
/// flat and a capture that has stopped are the two states where the user is
/// wearing the device believing it is recording when it is not; everything
/// else can wait for them to open the app.
enum CaptureAlert { lowBattery, captureStopped }

final class CaptureAlertSettings {
  const CaptureAlertSettings({
    this.lowBattery = true,
    this.captureStopped = true,
  });

  final bool lowBattery;
  final bool captureStopped;

  bool enabledFor(CaptureAlert alert) => switch (alert) {
    CaptureAlert.lowBattery => lowBattery,
    CaptureAlert.captureStopped => captureStopped,
  };

  CaptureAlertSettings copyWith({bool? lowBattery, bool? captureStopped}) =>
      CaptureAlertSettings(
        lowBattery: lowBattery ?? this.lowBattery,
        captureStopped: captureStopped ?? this.captureStopped,
      );
}

abstract interface class CaptureAlertSettingsStore {
  Future<CaptureAlertSettings> read();
  Future<void> save(CaptureAlertSettings settings);
}

final class PreferencesCaptureAlertSettingsStore
    implements CaptureAlertSettingsStore {
  static const _lowBatteryKey = 'capture_alert_low_battery_v1';
  static const _captureStoppedKey = 'capture_alert_capture_stopped_v1';

  @override
  Future<CaptureAlertSettings> read() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      return CaptureAlertSettings(
        lowBattery: preferences.getBool(_lowBatteryKey) ?? true,
        captureStopped: preferences.getBool(_captureStoppedKey) ?? true,
      );
    } catch (_) {
      // Storage is unavailable. Alerts default to on rather than silently off.
      return const CaptureAlertSettings();
    }
  }

  @override
  Future<void> save(CaptureAlertSettings settings) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_lowBatteryKey, settings.lowBattery);
      await preferences.setBool(_captureStoppedKey, settings.captureStopped);
    } catch (_) {}
  }
}

final class VolatileCaptureAlertSettingsStore
    implements CaptureAlertSettingsStore {
  VolatileCaptureAlertSettingsStore([
    this.settings = const CaptureAlertSettings(),
  ]);

  CaptureAlertSettings settings;

  @override
  Future<CaptureAlertSettings> read() async => settings;

  @override
  Future<void> save(CaptureAlertSettings value) async => settings = value;
}

/// How an alert reaches the user. One implementation talks to the platform;
/// everything else in this file is testable without it.
abstract interface class CaptureAlertPresenter {
  Future<void> present({
    required CaptureAlert alert,
    required String title,
    required String body,
  });
}

/// Raises the two alerts through `flutter_local_notifications` (BSD-3-Clause,
/// no telemetry). Initialisation is lazy and failures are swallowed: a phone
/// that refuses notification permission must still capture.
final class LocalCaptureAlertPresenter implements CaptureAlertPresenter {
  LocalCaptureAlertPresenter({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const _channelId = 'omi_capture_alerts';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  @override
  Future<void> present({
    required CaptureAlert alert,
    required String title,
    required String body,
  }) async {
    try {
      if (!_initialized) {
        await _plugin.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
            iOS: DarwinInitializationSettings(),
            macOS: DarwinInitializationSettings(),
          ),
        );
        _initialized = true;
      }
      await _plugin.show(
        id: alert.index,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Capture alerts',
            channelDescription:
                'Low pendant battery and capture stopping unexpectedly.',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }
}

final class RecordingCaptureAlertPresenter implements CaptureAlertPresenter {
  final presented = <({CaptureAlert alert, String title, String body})>[];

  @override
  Future<void> present({
    required CaptureAlert alert,
    required String title,
    required String body,
  }) async => presented.add((alert: alert, title: title, body: body));
}

/// Decides when the two alerts fire, and suppresses them when the user has
/// turned them off.
final class CaptureAlerts {
  CaptureAlerts({
    required this.presenter,
    required this.settingsStore,
    this.lowBatteryThreshold = 15,
    this.batteryRearmThreshold = 25,
  });

  final CaptureAlertPresenter presenter;
  final CaptureAlertSettingsStore settingsStore;

  /// Battery percentage at or below which the low-battery alert fires.
  final int lowBatteryThreshold;

  /// Battery percentage the pendant must climb back to before the low-battery
  /// alert can fire again. Without this the alert repeats on every notify at
  /// the threshold.
  final int batteryRearmThreshold;

  final settingsListenable = ValueNotifier<CaptureAlertSettings>(
    const CaptureAlertSettings(),
  );

  bool _lowBatteryArmed = true;

  Future<void> load() async =>
      settingsListenable.value = await settingsStore.read();

  Future<void> setEnabled(CaptureAlert alert, bool enabled) async {
    final next = switch (alert) {
      CaptureAlert.lowBattery => settingsListenable.value.copyWith(
        lowBattery: enabled,
      ),
      CaptureAlert.captureStopped => settingsListenable.value.copyWith(
        captureStopped: enabled,
      ),
    };
    settingsListenable.value = next;
    await settingsStore.save(next);
  }

  /// Feed every battery reading here; the crossing logic lives in one place.
  Future<void> batteryLevel(int percent) async {
    if (percent > batteryRearmThreshold) {
      _lowBatteryArmed = true;
      return;
    }
    if (percent > lowBatteryThreshold || !_lowBatteryArmed) return;
    _lowBatteryArmed = false;
    await _present(
      CaptureAlert.lowBattery,
      'Omi battery low',
      'Your Omi is at $percent%. Charge it to keep capturing.',
    );
  }

  /// Capture ended without the user asking it to. [detail] is a short,
  /// already-user-facing phrase.
  Future<void> captureStopped(String detail) =>
      _present(CaptureAlert.captureStopped, 'Omi stopped capturing', detail);

  Future<void> _present(CaptureAlert alert, String title, String body) async {
    if (!settingsListenable.value.enabledFor(alert)) return;
    await presenter.present(alert: alert, title: title, body: body);
  }

  void dispose() => settingsListenable.dispose();
}
