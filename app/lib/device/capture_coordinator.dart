import 'dart:async';

import '../native/native_hub.dart';
import '../storage/omi_directory.dart';
import 'background_capture.dart';
import 'capture_notifications.dart';
import 'device_audio_forwarder.dart';
import 'device_models.dart';
import 'device_relay.dart';
import 'hub_capture.dart';

/// The credentials sealed segments are uploaded with, resolved at the moment
/// they are needed. A null half means "not signed in", which leaves the audio
/// in the log rather than dropping it.
typedef CaptureUploadCredentials =
    Future<({String? endpoint, String? firebaseToken})> Function();

/// Ties the four capture-reliability pieces to one lifecycle: the hub's
/// write-ahead log, its uploader, background execution, and the two capture
/// alerts.
///
/// Everything here is optional at runtime. A platform with no background
/// service, a build with no upload endpoint and a user who has turned the
/// alerts off all degrade to "the log still records", which is the property
/// worth protecting.
final class CaptureCoordinator {
  CaptureCoordinator._({
    required this.capture,
    required this.alerts,
    required this.background,
    required this.uploadCredentials,
  });

  /// The seam onto the hub's log, or null when the hub is unavailable or the
  /// log could not be opened at all.
  final HubCapture? capture;
  final CaptureAlerts alerts;
  final BackgroundCaptureController background;
  final CaptureUploadCredentials? uploadCredentials;

  StreamSubscription<DeviceRelaySnapshot>? _snapshots;

  /// Opens the hub's log under the shared `.omi` directory and installs it on
  /// [forwarder]. A log that cannot be opened (read-only storage, no space) is
  /// reported and skipped rather than blocking capture.
  static Future<CaptureCoordinator> create({
    required DeviceAudioForwarder forwarder,
    required NativeHub hub,
    CaptureUploadCredentials? uploadCredentials,
    CaptureAlertPresenter? presenter,
    CaptureAlertSettingsStore? alertSettings,
    BackgroundCaptureController? background,
    String? walDirectory,
    void Function(Object error)? onError,
  }) async {
    HubCapture? capture;
    if (hub.available) {
      final opening = HubCapture(hub);
      try {
        final directory = walDirectory ?? (await omiDataDirectory()).path;
        if (await opening.open(directory: directory)) {
          capture = opening;
        } else {
          final failure = opening.lastError;
          opening.dispose();
          if (failure != null) onError?.call(failure);
        }
      } catch (error) {
        opening.dispose();
        onError?.call(error);
      }
    }
    final alerts = CaptureAlerts(
      presenter: presenter ?? LocalCaptureAlertPresenter(),
      settingsStore: alertSettings ?? PreferencesCaptureAlertSettingsStore(),
    );
    // Loaded in the background: capture must never wait on preferences, and
    // both alerts default to on until the stored answer arrives.
    unawaited(alerts.load().catchError((Object error) => onError?.call(error)));
    final coordinator = CaptureCoordinator._(
      capture: capture,
      alerts: alerts,
      background: background ?? BackgroundCaptureController(),
      uploadCredentials: uploadCredentials,
    );
    forwarder.capture = capture;
    forwarder.autoRestart = true;
    forwarder.onCaptureStopped = (reason) =>
        unawaited(alerts.captureStopped(reason));
    unawaited(coordinator._pump());
    return coordinator;
  }

  /// Watches the relay for battery readings so the low-battery alert has a
  /// source. The relay already subscribes to the battery characteristic; this
  /// only reads what it publishes.
  void watch(DeviceRelayService relay) {
    _snapshots?.cancel();
    _snapshots = relay.snapshots.listen((snapshot) {
      final level = snapshot.device?.batteryLevel;
      if (level != null) unawaited(alerts.batteryLevel(level));
    }, onError: (Object _) {});
  }

  /// Capture is live: hold the process (Android) and stop draining while the
  /// radio is busy.
  Future<void> captureStarted(RelayDevice device) async {
    await background.start(deviceName: device.name);
  }

  /// Capture ended: release the process and push whatever the log is holding.
  Future<void> captureStopped() async {
    await background.stop();
    unawaited(_pump());
  }

  Future<void> dispose() async {
    await _snapshots?.cancel();
    _snapshots = null;
    await capture?.close();
    capture?.dispose();
    alerts.dispose();
  }

  /// Refreshes the upload credentials and runs one pass.
  ///
  /// The hub drains on its own minute tick too, so this is the "something just
  /// changed, look now" path. The credentials are re-read every time because a
  /// Firebase id token outlives neither a long offline stretch nor a sign-out,
  /// and a stale one only ever costs a retry.
  Future<void> _pump() async {
    final target = capture;
    if (target == null) return;
    final credentials = uploadCredentials;
    if (credentials != null) {
      try {
        final resolved = await credentials();
        target.configureUpload(
          endpoint: resolved.endpoint,
          firebaseToken: resolved.firebaseToken,
        );
      } catch (_) {
        // Signed out, or the token could not be refreshed. The log keeps every
        // segment until it can.
      }
    }
    await target.drain();
  }
}
