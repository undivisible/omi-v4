import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/firmware_dfu.dart';
import 'package:omi/features/firmware_install.dart';
import 'package:omi/features/firmware_update_check.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the OTA package', () {
    test('parses a single-image manifest without an image index', () {
      final entries = parseFirmwareManifest(
        jsonEncode({
          'format-version': 0,
          'time': 1,
          'files': [
            {'file': 'app_update.bin', 'version': '3.2.0'},
          ],
        }),
      );

      expect(entries.single.image, 0);
      expect(entries.single.file, 'app_update.bin');
      expect(entries.single.version, '3.2.0');
    });

    test('refuses a multi-image manifest that does not name every slot', () {
      expect(
        () => parseFirmwareManifest(
          jsonEncode({
            'files': [
              {'file': 'app_update.bin', 'image_index': '0'},
              {'file': 'net_core_app_update.bin'},
            ],
          }),
        ),
        throwsFormatException,
      );
    });

    test('unpacks both cores of an nRF5340 package in manifest order', () {
      final images = readFirmwarePackage(
        _package(
          files: const {
            'app_update.bin': [1, 2, 3, 4],
            'net_core_app_update.bin': [9, 9],
          },
          manifest: {
            'format-version': 0,
            'time': 1,
            'files': [
              {'file': 'app_update.bin', 'image_index': '0'},
              {'file': 'net_core_app_update.bin', 'image_index': '1'},
            ],
          },
        ),
      );

      expect(images.map((image) => image.image), [0, 1]);
      expect(images.first.data, [1, 2, 3, 4]);
      expect(images.last.data, [9, 9]);
    });

    test('refuses a package whose manifest lists a file it does not '
        'carry', () {
      expect(
        () => readFirmwarePackage(
          _package(
            files: const {
              'app_update.bin': [1],
            },
            manifest: {
              'files': [
                {'file': 'somewhere_else.bin', 'image_index': '0'},
              ],
            },
          ),
        ),
        throwsFormatException,
      );
    });

    test('refuses bytes that are not a zip at all', () {
      expect(
        () => readFirmwarePackage(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
    });
  });

  group('artifact verification', () {
    const release = FirmwareRelease(
      version: '3.2.0',
      url: 'https://example.test/firmware-v3.2.0',
      assetName: 'dfu_application.zip',
      assetUrl: 'https://example.test/dfu_application.zip',
      sizeBytes: 4,
    );

    test('accepts bytes matching the published size and digest', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      expect(verifyFirmwareArtifact(release, bytes), isNull);
      expect(
        verifyFirmwareArtifact(
          FirmwareRelease(
            version: release.version,
            url: release.url,
            assetName: release.assetName,
            assetUrl: release.assetUrl,
            sizeBytes: 4,
            digest: 'sha256:${sha256.convert(bytes)}',
          ),
          bytes,
        ),
        isNull,
      );
    });

    test('refuses a truncated download', () {
      expect(
        verifyFirmwareArtifact(release, Uint8List.fromList([1, 2, 3])),
        contains('incomplete'),
      );
      expect(verifyFirmwareArtifact(release, Uint8List(0)), isNotNull);
    });

    test('refuses bytes that do not match the published checksum', () {
      expect(
        verifyFirmwareArtifact(
          const FirmwareRelease(
            version: '3.2.0',
            url: 'https://example.test/firmware-v3.2.0',
            assetName: 'dfu_application.zip',
            assetUrl: 'https://example.test/dfu_application.zip',
            sizeBytes: 4,
            digest:
                'sha256:'
                '0000000000000000000000000000000000000000000000000000000000000000',
          ),
          Uint8List.fromList([1, 2, 3, 4]),
        ),
        contains('checksum'),
      );
    });
  });

  group('the installer', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('omi-install');
    });
    tearDown(() => directory.delete(recursive: true));

    Future<
      ({
        FirmwareInstaller installer,
        _FakeHost host,
        _FakeFlasher flasher,
        List<FirmwareInstallStatus> seen,
      })
    >
    build({
      _FakeHost? host,
      _FakeFlasher? flasher,
      Uint8List? bytes,
      void Function(_FakeHost host)? onDownloaded,
    }) async {
      final installHost = host ?? _FakeHost();
      final installFlasher = flasher ?? _FakeFlasher();
      final payload = bytes ?? _defaultPackage;
      final installer = FirmwareInstaller(
        host: installHost,
        downloader: _FakeDownloader(
          directory: directory,
          bytes: payload,
          onDone: onDownloaded == null ? null : () => onDownloaded(installHost),
        ),
        flasher: installFlasher,
        settleDelay: Duration.zero,
      );
      final seen = <FirmwareInstallStatus>[];
      installer.addListener(() => seen.add(installer.status));
      return (
        installer: installer,
        host: installHost,
        flasher: installFlasher,
        seen: seen,
      );
    }

    test('installs, then confirms the version the pendant comes back '
        'with', () async {
      final fixture = await build();
      fixture.host.revisionAfterReconnect = '3.2.0';

      expect(await fixture.installer.install(_release()), isTrue);

      expect(fixture.host.released, 1);
      expect(fixture.host.reconnects, 1);
      expect(fixture.flasher.flashed.single.map((image) => image.image), [0]);
      expect(
        fixture.seen.map((status) => status.phase),
        containsAllInOrder(const [
          FirmwareInstallPhase.downloading,
          FirmwareInstallPhase.verifying,
          FirmwareInstallPhase.preparing,
          FirmwareInstallPhase.installing,
          FirmwareInstallPhase.confirming,
          FirmwareInstallPhase.installed,
        ]),
      );
      // Real progress, not a spinner: the flash fractions reach the UI.
      expect(
        fixture.seen
            .where((status) => status.phase == FirmwareInstallPhase.installing)
            .map((status) => status.progress),
        containsAllInOrder(const [0.25, 1.0]),
      );
    });

    test('refuses anything that is not strictly newer', () async {
      final fixture = await build();
      fixture.host.installedRevision = '3.2.0';

      expect(await fixture.installer.install(_release()), isFalse);

      expect(fixture.installer.status.phase, FirmwareInstallPhase.failed);
      expect(fixture.installer.status.message, contains('not newer'));
      expect(fixture.host.released, 0);
      expect(fixture.flasher.flashed, isEmpty);
    });

    test('a pendant without the SMP service is never flashed', () async {
      final fixture = await build();
      fixture.host.dfuSupported = false;

      expect(await fixture.installer.install(_release()), isFalse);

      expect(
        fixture.installer.status.message,
        firmwareInstallBlockMessage(FirmwareUpdateBlock.unsupported),
      );
      expect(fixture.installer.status.recovery, isNull);
      expect(fixture.host.released, 0);
    });

    test('the gate is re-checked at the start and again before the link is '
        'released', () async {
      // Charged when the button was pressed, flat by the time the package
      // finished downloading.
      final fixture = await build(
        onDownloaded: (host) => host.batteryLevel = 9,
      );

      expect(await fixture.installer.install(_release()), isFalse);

      expect(
        fixture.installer.status.message,
        firmwareInstallBlockMessage(FirmwareUpdateBlock.lowBattery),
      );
      expect(fixture.host.released, 0);
      expect(fixture.flasher.flashed, isEmpty);
    });

    test('a capture started mid-flash aborts before the swap', () async {
      final host = _FakeHost();
      final flasher = _FakeFlasher(
        steps: const [0.1, 0.2, 0.3],
        beforeEmit: () => host.capturing = true,
      );
      final fixture = await build(host: host, flasher: flasher);

      expect(await fixture.installer.install(_release()), isFalse);

      expect(fixture.installer.status.phase, FirmwareInstallPhase.failed);
      expect(
        fixture.installer.status.message,
        firmwareInstallBlockMessage(FirmwareUpdateBlock.capturing),
      );
      expect(
        fixture.installer.status.recovery,
        contains(
          'Nothing was '
          'swapped',
        ),
      );
      expect(flasher.cancelled, isTrue);
      expect(fixture.host.reconnects, 0);
    });

    test('a truncated artifact is never unpacked, let alone written', () async {
      final fixture = await build(
        bytes: Uint8List.fromList(_defaultPackage.sublist(0, 40)),
      );

      expect(
        await fixture.installer.install(
          _release(sizeBytes: _defaultPackage.length),
        ),
        isFalse,
      );

      expect(fixture.installer.status.message, contains('incomplete'));
      expect(fixture.host.released, 0);
      expect(fixture.flasher.flashed, isEmpty);
    });

    test('a pendant that reboots into the old image is reported as a '
        'failure', () async {
      final fixture = await build();
      fixture.host.revisionAfterReconnect = '3.1.0';

      expect(await fixture.installer.install(_release()), isFalse);

      expect(fixture.installer.status.message, contains('came back running'));
      expect(fixture.installer.status.recovery, contains('nRF Connect'));
    });

    test('a flash that fails leaves a recovery instruction, not a dead '
        'end', () async {
      final fixture = await build(
        flasher: _FakeFlasher(failure: StateError('link lost')),
      );

      expect(await fixture.installer.install(_release()), isFalse);

      expect(fixture.installer.status.phase, FirmwareInstallPhase.failed);
      expect(fixture.installer.status.recovery, contains('J-Link'));
    });
  });
}

FirmwareRelease _release({int? sizeBytes}) => FirmwareRelease(
  version: '3.2.0',
  url: 'https://example.test/firmware-v3.2.0',
  assetName: 'dfu_application.zip',
  assetUrl: 'https://example.test/dfu_application.zip',
  sizeBytes: sizeBytes,
);

final Uint8List _defaultPackage = _package(
  files: const {
    'app_update.bin': [1, 2, 3, 4, 5, 6, 7, 8],
  },
  manifest: const {
    'format-version': 0,
    'time': 1,
    'files': [
      {'file': 'app_update.bin', 'image_index': '0', 'version': '3.2.0'},
    ],
  },
);

Uint8List _package({
  required Map<String, List<int>> files,
  required Map<String, Object?> manifest,
}) {
  final archive = Archive();
  final manifestBytes = utf8.encode(jsonEncode(manifest));
  archive.add(
    ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
  );
  files.forEach(
    (name, bytes) => archive.add(ArchiveFile(name, bytes.length, bytes)),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

final class _FakeHost implements FirmwareInstallHost {
  @override
  String? installedRevision = '3.1.0';
  @override
  int? batteryLevel = 90;
  @override
  bool capturing = false;
  @override
  bool connected = true;
  @override
  bool dfuSupported = true;
  @override
  String? deviceId = 'omi-1';

  String? revisionAfterReconnect = '3.2.0';
  int released = 0;
  int reconnects = 0;

  @override
  Future<void> releaseLink() async {
    released += 1;
    connected = false;
  }

  @override
  Future<String?> reconnect() async {
    reconnects += 1;
    connected = true;
    installedRevision = revisionAfterReconnect;
    return revisionAfterReconnect;
  }
}

final class _FakeDownloader implements FirmwareDownloader {
  _FakeDownloader({required this.directory, required this.bytes, this.onDone});

  final Directory directory;
  final Uint8List bytes;

  /// Fires once the bytes have landed, so a test can drift the pendant's state
  /// exactly where a real download would have given it time to.
  final void Function()? onDone;

  @override
  Future<File> download(
    FirmwareRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(.5);
    onProgress?.call(1);
    final file = File('${directory.path}/${release.assetName}');
    await file.writeAsBytes(bytes);
    onDone?.call();
    return file;
  }
}

final class _FakeFlasher implements FirmwareFlasher {
  _FakeFlasher({this.steps = const [0.25, 1.0], this.failure, this.beforeEmit});

  final List<double> steps;
  final Object? failure;

  /// Fires just before each progress event reaches the installer, which is
  /// where a mid-flash change of heart lands.
  final void Function()? beforeEmit;
  final flashed = <List<FirmwareImage>>[];
  bool cancelled = false;

  @override
  Stream<FirmwareFlashProgress> flash({
    required String deviceId,
    required List<FirmwareImage> images,
  }) {
    flashed.add(images);
    late final StreamController<FirmwareFlashProgress> controller;
    controller = StreamController<FirmwareFlashProgress>(
      onListen: () async {
        for (final step in steps) {
          if (controller.isClosed) return;
          beforeEmit?.call();
          if (controller.isClosed) return;
          controller.add(
            FirmwareFlashProgress(FirmwareFlashStage.uploading, step),
          );
          await Future<void>.delayed(Duration.zero);
        }
        if (controller.isClosed) return;
        if (failure != null) {
          controller.addError(failure!);
        }
        await controller.close();
      },
      onCancel: () => cancelled = true,
    );
    return controller.stream;
  }
}
