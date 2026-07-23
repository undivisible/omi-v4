import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../device/firmware_dfu.dart';
import 'firmware_update_check.dart';
import 'mobile_update_check.dart' show compareVersions;

/// What the app has to be able to ask of, and do to, the pendant for an install
/// to run. Implemented by the mobile shell over `DeviceRelayService`; faked in
/// tests so the whole flow — including every refusal — runs without hardware.
abstract interface class FirmwareInstallHost {
  /// The BLE identifier the DFU transport connects to. Survives
  /// [releaseLink] so the flash still knows where to go once the app has let
  /// go of the connection.
  String? get deviceId;

  /// DIS firmware revision `0x2A26` as last read from the pendant.
  String? get installedRevision;

  bool get connected;
  bool get dfuSupported;
  bool get capturing;
  int? get batteryLevel;

  /// Stops capture and drops the app's own GATT connection. mcumgr opens its
  /// own link and will fight the relay's if the relay keeps holding one.
  Future<void> releaseLink();

  /// Reconnects after the pendant reboots and returns the firmware revision it
  /// reports then — the only honest confirmation that the image took.
  Future<String?> reconnect();
}

enum FirmwareInstallPhase {
  idle,
  downloading,
  verifying,
  preparing,
  installing,
  confirming,
  installed,
  failed,
}

/// A snapshot of an install, including the recovery line a failure leaves
/// behind. Never a bare error: a pendant that would not take an image has to
/// leave the user with somewhere to go.
final class FirmwareInstallStatus {
  const FirmwareInstallStatus({
    required this.phase,
    this.progress,
    this.message,
    this.recovery,
  });

  static const idle = FirmwareInstallStatus(phase: FirmwareInstallPhase.idle);

  final FirmwareInstallPhase phase;

  /// 0..1 within the current phase, or null when the phase has no fraction.
  final double? progress;
  final String? message;

  /// What to do next when [phase] is [FirmwareInstallPhase.failed].
  final String? recovery;

  bool get busy => switch (phase) {
    FirmwareInstallPhase.downloading ||
    FirmwareInstallPhase.verifying ||
    FirmwareInstallPhase.preparing ||
    FirmwareInstallPhase.installing ||
    FirmwareInstallPhase.confirming => true,
    _ => false,
  };

  /// True once the image has been handed over far enough that stopping is no
  /// longer free. Up to that point an abort leaves the pendant untouched.
  bool get committed => phase == FirmwareInstallPhase.installing;
}

/// What the app tells a user whose pendant refused, or failed, an update. There
/// is no rollback slot on `omi-cv1`, so the honest answer when the BLE path
/// gives up is the wired one rather than "try again" forever.
const firmwareRecoveryInstruction =
    'Your pendant keeps the firmware it had unless the update reached the '
    'reboot. If it no longer connects, reflash it over USB with nRF Connect '
    'for Desktop (Programmer) or a J-Link, using the merged.hex from the same '
    'release.';

/// Runs a firmware install end to end: download, verify, unpack, hand the link
/// to the DFU transport, flash, reconnect, and confirm the version the pendant
/// reports afterwards.
///
/// Every refusal is deliberate and stated. `omi-cv1` runs MCUboot overwrite-only
/// with downgrade prevention, so an image that is not strictly newer, or one
/// whose bytes do not match what the release published, is never written.
final class FirmwareInstaller extends ChangeNotifier {
  FirmwareInstaller({
    required this.host,
    required this.downloader,
    required this.flasher,
    List<FirmwareImage> Function(Uint8List bytes)? readPackage,
    this.settleDelay = const Duration(seconds: 2),
  }) : _readPackage = readPackage ?? readFirmwarePackage;

  final FirmwareInstallHost host;
  final FirmwareDownloader downloader;
  final FirmwareFlasher flasher;
  final List<FirmwareImage> Function(Uint8List bytes) _readPackage;

  /// Time between dropping the app's connection and opening the DFU one. The
  /// platform BLE stack needs a moment to release the peripheral.
  final Duration settleDelay;

  FirmwareInstallStatus _status = FirmwareInstallStatus.idle;
  FirmwareInstallStatus get status => _status;

  StreamSubscription<FirmwareFlashProgress>? _flash;
  Completer<void>? _uploadDone;
  bool _abortRequested = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    unawaited(_flash?.cancel());
    _flash = null;
    super.dispose();
  }

  void _emit(FirmwareInstallStatus next) {
    if (_disposed) return;
    _status = next;
    notifyListeners();
  }

  // Every failure names its own way out; a refusal that happens before
  // anything is written passes null rather than pointing at a J-Link the user
  // does not need.
  bool _fail(String message, {required String? recovery}) {
    _emit(
      FirmwareInstallStatus(
        phase: FirmwareInstallPhase.failed,
        message: message,
        recovery: recovery,
      ),
    );
    return false;
  }

  /// Asks a running install to stop. Free while the upload is still streaming
  /// — MCUboot only swaps once a whole image has landed — so this is offered
  /// right up to the reboot.
  void abort() {
    if (!_status.busy) return;
    _abortRequested = true;
    unawaited(_flash?.cancel());
    _flash = null;
    // A download in flight cannot be torn out from under `http`, so the flag is
    // what stops the flow: it is re-read before anything is written.
    final pending = _uploadDone;
    _uploadDone = null;
    if (pending != null && !pending.isCompleted) pending.complete();
    _emit(
      const FirmwareInstallStatus(
        phase: FirmwareInstallPhase.failed,
        message: 'Update stopped. Your pendant kept the firmware it had.',
      ),
    );
  }

  /// Returns true only when the pendant came back reporting [release]'s
  /// version.
  Future<bool> install(FirmwareRelease release) async {
    if (_status.busy) return false;
    _abortRequested = false;

    final installed = host.installedRevision?.trim();
    if (installed == null || installed.isEmpty) {
      return _fail(
        'Your pendant did not report which firmware it is running, so the '
        'update cannot be checked against it.',
        recovery: 'Reconnect the pendant and try again.',
      );
    }
    // Downgrade prevention lives in the bootloader too, but a rejected image
    // still costs a full upload and a reboot, so refuse here first.
    if (compareVersions(release.version, installed) <= 0) {
      return _fail(
        'Firmware ${release.version} is not newer than the $installed your '
        'pendant runs. This bootloader refuses anything that is not a step '
        'forward.',
        recovery: 'Nothing to do — your pendant is already up to date.',
      );
    }

    final blocked = firmwareUpdateBlock(
      connected: host.connected,
      dfuSupported: host.dfuSupported,
      capturing: host.capturing,
      batteryLevel: host.batteryLevel,
    );
    if (blocked != FirmwareUpdateBlock.none) {
      return _fail(firmwareInstallBlockMessage(blocked), recovery: null);
    }

    // Pinned before the link is released: the shell forgets the connected
    // device the moment the relay disconnects.
    final deviceId = host.deviceId;
    if (deviceId == null) {
      return _fail('Connect your pendant before updating it.', recovery: null);
    }

    Uint8List bytes;
    try {
      _emit(
        const FirmwareInstallStatus(
          phase: FirmwareInstallPhase.downloading,
          progress: 0,
          message: 'Downloading the update package.',
        ),
      );
      final file = await downloader.download(
        release,
        onProgress: (progress) => _emit(
          FirmwareInstallStatus(
            phase: FirmwareInstallPhase.downloading,
            progress: progress,
            message: 'Downloading the update package.',
          ),
        ),
      );
      if (_abortRequested) return false;
      bytes = await file.readAsBytes();
    } catch (error) {
      return _fail(
        'The update could not be downloaded: $error',
        recovery:
            'Check your connection and try again. Your pendant was not '
            'touched.',
      );
    }

    _emit(
      const FirmwareInstallStatus(
        phase: FirmwareInstallPhase.verifying,
        message: 'Checking the package before writing anything.',
      ),
    );
    final rejected = verifyFirmwareArtifact(release, bytes);
    if (rejected != null) return _fail(rejected, recovery: 'Try again.');

    List<FirmwareImage> images;
    try {
      images = _readPackage(bytes);
    } catch (error) {
      return _fail(
        'The update package is not one this pendant can take: $error',
        recovery:
            'Try again, or install this release with nRF Connect for '
            'Mobile.',
      );
    }
    if (images.isEmpty) {
      return _fail(
        'The update package contains no firmware images.',
        recovery: 'Try again.',
      );
    }
    if (_abortRequested) return false;

    // Re-checked immediately before the link is handed over, not only when the
    // button was pressed: a download takes long enough for the battery to fall
    // or a capture to start.
    final blockedNow = firmwareUpdateBlock(
      connected: host.connected,
      dfuSupported: host.dfuSupported,
      capturing: host.capturing,
      batteryLevel: host.batteryLevel,
    );
    if (blockedNow != FirmwareUpdateBlock.none) {
      return _fail(firmwareInstallBlockMessage(blockedNow), recovery: null);
    }

    _emit(
      const FirmwareInstallStatus(
        phase: FirmwareInstallPhase.preparing,
        message: 'Freeing the Bluetooth link for the update.',
      ),
    );
    try {
      await host.releaseLink();
      await Future<void>.delayed(settleDelay);
    } catch (error) {
      return _fail(
        'The pendant connection could not be released: $error',
        recovery: 'Reconnect the pendant and try again.',
      );
    }
    if (_abortRequested) return false;

    try {
      await _upload(deviceId, images);
    } on _FirmwareInstallAborted catch (aborted) {
      return _fail(aborted.message, recovery: aborted.recovery);
    } catch (error) {
      return _fail(
        'The update could not be written: $error',
        recovery: firmwareRecoveryInstruction,
      );
    }
    if (_abortRequested) return false;

    _emit(
      const FirmwareInstallStatus(
        phase: FirmwareInstallPhase.confirming,
        message: 'Waiting for your pendant to come back.',
      ),
    );
    String? revision;
    try {
      revision = await host.reconnect();
    } catch (error) {
      return _fail(
        'Your pendant did not come back after the update: $error',
        recovery: firmwareRecoveryInstruction,
      );
    }
    if (revision == null || revision.trim().isEmpty) {
      return _fail(
        'Your pendant reconnected but did not report its firmware version, so '
        'the update cannot be confirmed.',
        recovery: 'Reconnect it and check the version in developer options.',
      );
    }
    if (compareVersions(revision.trim(), release.version) != 0) {
      return _fail(
        'Your pendant came back running $revision, not ${release.version}. '
        'The image was not applied.',
        recovery: firmwareRecoveryInstruction,
      );
    }
    _emit(
      FirmwareInstallStatus(
        phase: FirmwareInstallPhase.installed,
        progress: 1,
        message: 'Your pendant is running firmware ${release.version}.',
      ),
    );
    return true;
  }

  Future<void> _upload(String deviceId, List<FirmwareImage> images) async {
    final done = Completer<void>();
    _uploadDone = done;
    _emit(
      const FirmwareInstallStatus(
        phase: FirmwareInstallPhase.installing,
        progress: 0,
        message: 'Writing the update. Keep your phone nearby.',
      ),
    );
    _flash = flasher
        .flash(deviceId: deviceId, images: images)
        .listen(
          (progress) {
            // Battery is the last value read before the link was released, so
            // this is a floor check on a stale reading rather than a live one —
            // an honest capture restart is the case it really catches.
            final abort = firmwareUpdateAbort(
              capturing: host.capturing,
              batteryLevel: host.batteryLevel,
            );
            if (abort != FirmwareUpdateBlock.none) {
              unawaited(_flash?.cancel());
              _flash = null;
              if (!done.isCompleted) {
                done.completeError(
                  _FirmwareInstallAborted(
                    firmwareInstallBlockMessage(abort),
                    'Nothing was swapped: the pendant still boots the '
                    'firmware it had. Start the update again when it is '
                    'idle and charged.',
                  ),
                );
              }
              return;
            }
            _emit(
              FirmwareInstallStatus(
                phase: FirmwareInstallPhase.installing,
                progress: progress.progress,
                message: switch (progress.stage) {
                  FirmwareFlashStage.preparing => 'Opening the update channel.',
                  FirmwareFlashStage.uploading =>
                    'Writing the update. Keep your phone nearby.',
                  FirmwareFlashStage.swapping =>
                    'Your pendant is rebooting into the new firmware.',
                },
              ),
            );
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!done.isCompleted) done.completeError(error, stackTrace);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
        );
    try {
      await done.future;
    } finally {
      _uploadDone = null;
      await _flash?.cancel();
      _flash = null;
    }
  }
}

final class _FirmwareInstallAborted implements Exception {
  const _FirmwareInstallAborted(this.message, this.recovery);

  final String message;
  final String recovery;
}

/// Rejects a package that is not exactly what the release published. Returns
/// null when the bytes are good, or the reason they are not.
///
/// A truncated download is the failure mode that matters: MCUboot on this
/// target is overwrite-only, so half an image is not something to discover
/// after the swap.
String? verifyFirmwareArtifact(FirmwareRelease release, Uint8List bytes) {
  if (bytes.isEmpty) return 'The downloaded update package is empty.';
  final expected = release.sizeBytes;
  if (expected != null && expected > 0 && bytes.length != expected) {
    return 'The download is incomplete (${bytes.length} of $expected bytes). '
        'Nothing was written to your pendant.';
  }
  final digest = release.digest;
  if (digest == null) return null;
  final separator = digest.indexOf(':');
  if (separator <= 0) return null;
  final algorithm = digest.substring(0, separator).toLowerCase();
  final expectedHex = digest.substring(separator + 1).toLowerCase();
  if (algorithm != 'sha256' || expectedHex.isEmpty) return null;
  if (sha256.convert(bytes).toString() != expectedHex) {
    return 'The downloaded package does not match the checksum this release '
        'published. Nothing was written to your pendant.';
  }
  return null;
}

/// The user-facing reason an install cannot run, shared by the update screen
/// and the installer so a mid-flow abort reads like the pre-flight refusal.
String firmwareInstallBlockMessage(
  FirmwareUpdateBlock block,
) => switch (block) {
  FirmwareUpdateBlock.none => 'Ready to install.',
  FirmwareUpdateBlock.disconnected =>
    'Connect your pendant before updating '
        'it.',
  FirmwareUpdateBlock.unsupported =>
    'This pendant cannot take an update over Bluetooth.',
  FirmwareUpdateBlock.lowBattery =>
    'Charge your pendant to at least $firmwareUpdateMinimumBattery% first: an '
        'update that runs out of power mid-write cannot be undone.',
  FirmwareUpdateBlock.capturing =>
    'Turn capture off first — updating interrupts the audio stream.',
};
