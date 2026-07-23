import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:mcumgr_flutter/mcumgr_flutter.dart' as mcumgr;
import 'package:mcumgr_flutter/models/firmware_upgrade_mode.dart'
    show FirmwareUpgradeMode;

/// One signed image out of a `dfu_application.zip`. The nRF5340 publishes two —
/// the application core and the network core — and MCUboot needs both handed to
/// it in the same upload, keyed by the manifest's `image_index`.
final class FirmwareImage {
  const FirmwareImage({
    required this.image,
    required this.file,
    required this.data,
    this.version,
  });

  /// The MCUboot image number (`image_index` in the manifest, 0 for a
  /// single-core build).
  final int image;

  /// The name the manifest gave this image, kept for error messages.
  final String file;
  final Uint8List data;
  final String? version;

  @override
  String toString() => 'FirmwareImage($image, $file, ${data.length} bytes)';
}

/// An entry of the OTA package's `manifest.json`, before its bytes are read.
typedef FirmwareManifestEntry = ({int image, String file, String? version});

/// Parses the `manifest.json` that `west`/nRF Connect SDK writes into
/// `dfu_application.zip`.
///
/// The shape is upstream Nordic's, and the one rule worth enforcing is theirs
/// too: a package carrying more than one image must name the slot for every one
/// of them, because guessing which blob is the network core is how a pendant
/// gets a working application core paired with a broken radio.
List<FirmwareManifestEntry> parseFirmwareManifest(String source) {
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } catch (error) {
    throw FormatException('manifest.json is not valid JSON: $error');
  }
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('manifest.json is not an object');
  }
  final files = decoded['files'];
  if (files is! List<Object?> || files.isEmpty) {
    throw const FormatException('manifest.json lists no firmware files');
  }
  final entries = <FirmwareManifestEntry>[];
  for (final entry in files) {
    if (entry is! Map<String, Object?>) {
      throw const FormatException('manifest.json has a malformed file entry');
    }
    final file = entry['file'];
    if (file is! String || file.isEmpty) {
      throw const FormatException(
        'manifest.json has a file entry with no '
        'name',
      );
    }
    final index = entry['image_index'];
    final version = entry['version'];
    entries.add((
      image: switch (index) {
        final int value => value,
        final String value when int.tryParse(value) != null => int.parse(value),
        null when files.length == 1 => 0,
        _ => throw FormatException(
          'manifest.json entry "$file" has no usable image_index',
        ),
      },
      file: file,
      version: version is String && version.isNotEmpty ? version : null,
    ));
  }
  return entries;
}

/// Unpacks a downloaded `dfu_application.zip` into the images MCUboot takes.
///
/// Pure Dart (the `archive` package) rather than a platform unzip, so the whole
/// path — including a truncated or mis-built package — is exercised in tests
/// without a device.
List<FirmwareImage> readFirmwarePackage(Uint8List zipBytes) {
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zipBytes);
  } catch (error) {
    throw FormatException('The update package could not be opened: $error');
  }
  final byName = <String, ArchiveFile>{};
  for (final file in archive.files) {
    if (!file.isFile) continue;
    byName[file.name] = file;
    // Some packagers nest everything under a single directory; index the leaf
    // name too so the manifest's relative paths still resolve.
    final leaf = file.name.split('/').last;
    byName.putIfAbsent(leaf, () => file);
  }
  final manifestFile = byName['manifest.json'];
  if (manifestFile == null) {
    throw const FormatException('The update package carries no manifest.json');
  }
  final manifestBytes = manifestFile.readBytes();
  if (manifestBytes == null) {
    throw const FormatException('manifest.json could not be read');
  }
  final entries = parseFirmwareManifest(utf8.decode(manifestBytes));
  final images = <FirmwareImage>[];
  for (final entry in entries) {
    final file = byName[entry.file] ?? byName[entry.file.split('/').last];
    if (file == null) {
      throw FormatException(
        'The update package is missing "${entry.file}", which its manifest '
        'lists',
      );
    }
    final data = file.readBytes();
    if (data == null || data.isEmpty) {
      throw FormatException('"${entry.file}" is empty in the update package');
    }
    images.add(
      FirmwareImage(
        image: entry.image,
        file: entry.file,
        data: data,
        version: entry.version,
      ),
    );
  }
  return images;
}

/// Where a flash has got to. [progress] is null while the phase has no
/// meaningful fraction (setup, and the reboot/swap after the upload).
final class FirmwareFlashProgress {
  const FirmwareFlashProgress(this.stage, [this.progress]);

  final FirmwareFlashStage stage;
  final double? progress;

  @override
  String toString() => 'FirmwareFlashProgress($stage, $progress)';
}

enum FirmwareFlashStage { preparing, uploading, swapping }

/// Writes images to a pendant over SMP/mcumgr.
///
/// The stream reports progress, closes when the device has taken and confirmed
/// the image, and errors on any failure. Cancelling the subscription aborts the
/// transfer — safe while the upload is still running, because MCUboot only
/// swaps once the whole image has landed in the secondary slot.
abstract interface class FirmwareFlasher {
  Stream<FirmwareFlashProgress> flash({
    required String deviceId,
    required List<FirmwareImage> images,
  });
}

/// The real transport, on Nordic's `mcumgr_flutter` (BSD-3-Clause).
///
/// Adapted from upstream Omi's `FirmwareMixin.startMCUDfu`
/// (github.com/BasedHardware/omi, MIT), with one deliberate difference:
/// [eraseAppSettings] is false. Upstream sets it true, which erases the NVS
/// partition — on this firmware that is where the persisted device name
/// (19b10016) and the mic gain live, so a "successful" update would silently
/// reset both.
final class McuMgrFirmwareFlasher implements FirmwareFlasher {
  McuMgrFirmwareFlasher({mcumgr.UpdateManagerFactory? factory})
    : _factory = factory ?? mcumgr.FirmwareUpdateManagerFactory();

  /// `confirmOnly` matches the bootloader: `omi-cv1` runs MCUboot overwrite-only
  /// with downgrade prevention, so there is no revert slot for the
  /// test-then-confirm dance to fall back to.
  static const configuration = mcumgr.FirmwareUpgradeConfiguration(
    estimatedSwapTime: Duration(seconds: 0),
    eraseAppSettings: false,
    pipelineDepth: 1,
    firmwareUpgradeMode: FirmwareUpgradeMode.confirmOnly,
  );

  final mcumgr.UpdateManagerFactory _factory;

  @override
  Stream<FirmwareFlashProgress> flash({
    required String deviceId,
    required List<FirmwareImage> images,
  }) {
    mcumgr.FirmwareUpdateManager? manager;
    StreamSubscription<mcumgr.FirmwareUpgradeState>? states;
    StreamSubscription<mcumgr.ProgressUpdate>? progress;
    late final StreamController<FirmwareFlashProgress> controller;

    Future<void> teardown() async {
      await states?.cancel();
      await progress?.cancel();
      states = null;
      progress = null;
      final open = manager;
      manager = null;
      if (open == null) return;
      try {
        await open.kill();
      } catch (_) {}
    }

    Future<void> start() async {
      try {
        controller.add(
          const FirmwareFlashProgress(FirmwareFlashStage.preparing),
        );
        final update = await _factory.getUpdateManager(deviceId);
        manager = update;
        states = update.setup().listen(
          (state) {
            if (controller.isClosed) return;
            if (state == mcumgr.FirmwareUpgradeState.success) {
              unawaited(controller.close());
              return;
            }
            controller.add(FirmwareFlashProgress(_stage(state)));
          },
          onError: (Object error, StackTrace stackTrace) {
            if (controller.isClosed) return;
            controller.addError(error, stackTrace);
            unawaited(controller.close());
          },
          // The platform side closes the state stream once the upgrade is
          // done; the success event above is what marks it as succeeded, so a
          // close on its own only has to stop the flow.
          onDone: () {
            if (!controller.isClosed) unawaited(controller.close());
          },
        );
        progress = update.progressStream.listen((update) {
          if (controller.isClosed || update.imageSize <= 0) return;
          controller.add(
            FirmwareFlashProgress(
              FirmwareFlashStage.uploading,
              (update.bytesSent / update.imageSize).clamp(0.0, 1.0),
            ),
          );
        }, onError: (Object _) {});
        await update.update([
          for (final image in images)
            mcumgr.Image(image: image.image, data: image.data),
        ], configuration: configuration);
      } catch (error, stackTrace) {
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
          unawaited(controller.close());
        }
      }
    }

    controller = StreamController<FirmwareFlashProgress>(
      onListen: () => unawaited(start()),
      onCancel: teardown,
    );
    return controller.stream;
  }

  static FirmwareFlashStage _stage(mcumgr.FirmwareUpgradeState state) =>
      switch (state) {
        mcumgr.FirmwareUpgradeState.upload => FirmwareFlashStage.uploading,
        mcumgr.FirmwareUpgradeState.test ||
        mcumgr.FirmwareUpgradeState.reset ||
        mcumgr.FirmwareUpgradeState.confirm => FirmwareFlashStage.swapping,
        _ => FirmwareFlashStage.preparing,
      };
}
