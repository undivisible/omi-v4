import 'dart:async';
import 'dart:io';

import '../storage/omi_directory.dart';
import 'background_capture.dart';
import 'capture_gap_log.dart';
import 'capture_notifications.dart';
import 'capture_upload.dart';
import 'capture_wal.dart';
import 'capture_wal_uploader.dart';
import 'device_audio_forwarder.dart';
import 'device_models.dart';
import 'device_relay.dart';

/// Ties the four capture-reliability pieces to one lifecycle: the write-ahead
/// log, its uploader, background execution, and the two capture alerts.
///
/// Everything here is optional at runtime. A platform with no background
/// service, a build with no upload endpoint and a user who has turned the
/// alerts off all degrade to "the log still records", which is the property
/// worth protecting.
final class CaptureCoordinator {
  CaptureCoordinator._({
    required this.wal,
    required this.uploader,
    required this.alerts,
    required this.background,
    required this.gaps,
  });

  final CaptureWal? wal;
  final CaptureWalUploader? uploader;
  final CaptureAlerts alerts;
  final BackgroundCaptureController background;
  final CaptureGapRecorder gaps;

  StreamSubscription<DeviceRelaySnapshot>? _snapshots;

  /// Opens the log under the shared `.omi` directory and installs it on
  /// [forwarder]. A log that cannot be opened (read-only storage, no space) is
  /// reported and skipped rather than blocking capture.
  static Future<CaptureCoordinator> create({
    required DeviceAudioForwarder forwarder,
    CaptureUploadTransport transport =
        const UnavailableCaptureUploadTransport(),
    CaptureGapRecorder? gapRecorder,
    CaptureAlertPresenter? presenter,
    CaptureAlertSettingsStore? alertSettings,
    BackgroundCaptureController? background,
    Directory? walDirectory,
    void Function(Object error)? onError,
  }) async {
    CaptureWal? wal;
    try {
      wal = await CaptureWal.open(
        directory:
            walDirectory ??
            Directory(
              '${(await omiDataDirectory()).path}'
              '${Platform.pathSeparator}capture-wal',
            ),
      );
    } catch (error) {
      onError?.call(error);
    }
    final gaps = gapRecorder ?? PreferencesCaptureGapLog();
    final alerts = CaptureAlerts(
      presenter: presenter ?? LocalCaptureAlertPresenter(),
      settingsStore: alertSettings ?? PreferencesCaptureAlertSettingsStore(),
    );
    // Loaded in the background: capture must never wait on preferences, and
    // both alerts default to on until the stored answer arrives.
    unawaited(alerts.load().catchError((Object error) => onError?.call(error)));
    final uploader = wal == null
        ? null
        : CaptureWalUploader(wal: wal, transport: transport);
    final coordinator = CaptureCoordinator._(
      wal: wal,
      uploader: uploader,
      alerts: alerts,
      background: background ?? BackgroundCaptureController(),
      gaps: gaps,
    );
    forwarder.wal = wal;
    forwarder.gapRecorder = gaps;
    forwarder.autoRestart = true;
    forwarder.onCaptureStopped = (reason) =>
        unawaited(alerts.captureStopped(reason));
    uploader?.start();
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
    unawaited(uploader?.drain() ?? Future<int>.value(0));
  }

  Future<void> dispose() async {
    await _snapshots?.cancel();
    _snapshots = null;
    uploader?.dispose();
    alerts.dispose();
    await wal?.close();
  }
}
