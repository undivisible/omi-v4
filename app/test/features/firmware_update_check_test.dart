import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/features/firmware_update_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('reports the newest firmware release with an OTA package', () async {
    final release = await _checker([
      _release('firmware-v3.1.0'),
      // The app channel shares the repository and must be ignored.
      _release('mobile-v9.9.9'),
      _release('firmware-v3.2.0'),
      _release('firmware-v3.3.0', draft: true),
      _release('firmware-v3.4.0', prerelease: true),
      // Published without an OTA package: nothing the app could install.
      _release('firmware-v3.9.0', assets: const []),
    ]).check(installedRevision: '3.1.0');

    expect(release?.version, '3.2.0');
    expect(release?.assetName, 'dfu_application.zip');
    expect(
      release?.assetUrl,
      'https://example.test/firmware-v3.2.0/dfu_application.zip',
    );
    expect(release?.sizeBytes, 440320);
    expect(release?.digest, 'sha256:$_digest');
  });

  test('stays quiet when the pendant is current or newer', () async {
    Future<FirmwareRelease?> against(String installed) => _checker([
      _release('firmware-v3.1.0'),
    ]).check(installedRevision: installed);

    expect(await against('3.1.0'), isNull);
    expect(await against('3.2.0'), isNull);
    expect((await against('3.0.9'))?.version, '3.1.0');
  });

  test('a pendant that never reported its revision is not offered an '
      'update', () async {
    final checker = _checker([_release('firmware-v3.1.0')]);

    expect(await checker.check(installedRevision: null), isNull);
    expect(await checker.check(installedRevision: '  '), isNull);
  });

  test('picks the package matching the build target', () async {
    final release = await _checker([
      _release(
        'firmware-v3.2.0',
        assets: const [
          'omi-cv1-dfu_application.zip',
          'devkit-v1-dfu_application.zip',
        ],
      ),
    ]).check(installedRevision: '3.1.0', target: 'omi-cv1');

    expect(release?.assetName, 'omi-cv1-dfu_application.zip');
  });

  test('refuses to guess between several packages', () async {
    final release = await _checker([
      _release(
        'firmware-v3.2.0',
        assets: const [
          'omi-cv1-dfu_application.zip',
          'devkit-v1-dfu_application.zip',
        ],
      ),
    ]).check(installedRevision: '3.1.0', target: 'Omi Something Else');

    expect(release, isNull);
  });

  test('a dismissed version stays dismissed until something newer', () async {
    final feed = [_release('firmware-v3.2.0')];
    final release = await _checker(feed).check(installedRevision: '3.1.0');
    await _checker(feed).dismiss(release!);

    expect(await _checker(feed).check(installedRevision: '3.1.0'), isNull);
    expect(
      (await _checker([
        _release('firmware-v3.3.0'),
      ]).check(installedRevision: '3.1.0'))?.version,
      '3.3.0',
    );
  });

  test('every failure mode resolves to no update', () async {
    Future<FirmwareRelease?> check(http.Client client) => FirmwareUpdateChecker(
      endpoint: 'https://example.test/releases',
      client: client,
    ).check(installedRevision: '3.1.0');

    expect(
      await check(MockClient((_) async => http.Response('nope', 404))),
      isNull,
    );
    expect(
      await check(MockClient((_) async => http.Response('{not json', 200))),
      isNull,
    );
    expect(
      await check(MockClient((_) async => throw const SocketException('down'))),
      isNull,
    );
  });

  group('the pre-flight gate', () {
    FirmwareUpdateBlock block({
      bool connected = true,
      bool dfuSupported = true,
      bool capturing = false,
      int? batteryLevel = 90,
    }) => firmwareUpdateBlock(
      connected: connected,
      dfuSupported: dfuSupported,
      capturing: capturing,
      batteryLevel: batteryLevel,
    );

    test('lets a charged, idle, supported pendant through', () {
      expect(block(), FirmwareUpdateBlock.none);
      // An unreported battery cannot be judged, so it does not block.
      expect(block(batteryLevel: null), FirmwareUpdateBlock.none);
    });

    test('refuses a low battery', () {
      expect(
        block(batteryLevel: firmwareUpdateMinimumBattery - 1),
        FirmwareUpdateBlock.lowBattery,
      );
      expect(
        block(batteryLevel: firmwareUpdateMinimumBattery),
        FirmwareUpdateBlock.none,
      );
    });

    test('refuses while capture is streaming', () {
      expect(block(capturing: true), FirmwareUpdateBlock.capturing);
    });

    test('unsupported and disconnected outrank the rest', () {
      expect(
        block(dfuSupported: false, capturing: true, batteryLevel: 5),
        FirmwareUpdateBlock.unsupported,
      );
      expect(
        block(connected: false, dfuSupported: false),
        FirmwareUpdateBlock.disconnected,
      );
    });
  });

  test('the downloader streams to a file and reports progress', () async {
    final directory = await Directory.systemTemp.createTemp('omi-firmware');
    addTearDown(() => directory.delete(recursive: true));
    final progress = <double>[];

    final file =
        await HttpFirmwareDownloader(
          directory: directory,
          client: MockClient.streaming(
            (request, body) async => http.StreamedResponse(
              Stream.fromIterable([
                [1, 2, 3, 4],
                [5, 6, 7, 8],
              ]),
              200,
              contentLength: 8,
            ),
          ),
        ).download(
          const FirmwareRelease(
            version: '3.2.0',
            url: 'https://example.test/firmware-v3.2.0',
            assetName: 'dfu_application.zip',
            assetUrl: 'https://example.test/dfu_application.zip',
          ),
          onProgress: progress.add,
        );

    expect(await file.readAsBytes(), [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(progress, [0.5, 1.0, 1.0]);
  });

  test('a refused download leaves an error, not a silent success', () async {
    final directory = await Directory.systemTemp.createTemp('omi-firmware');
    addTearDown(() => directory.delete(recursive: true));

    await expectLater(
      HttpFirmwareDownloader(
        directory: directory,
        client: MockClient((_) async => http.Response('gone', 404)),
      ).download(
        const FirmwareRelease(
          version: '3.2.0',
          url: 'https://example.test/firmware-v3.2.0',
          assetName: 'dfu_application.zip',
          assetUrl: 'https://example.test/dfu_application.zip',
        ),
      ),
      throwsA(isA<HttpException>()),
    );
  });
}

// Stands in for the digest GitHub publishes per asset; the installer refuses
// bytes that do not hash to it.
const _digest =
    '0000000000000000000000000000000000000000000000000000000000000001';

FirmwareUpdateChecker _checker(List<Map<String, Object?>> feed) =>
    FirmwareUpdateChecker(
      endpoint: 'https://example.test/releases',
      client: MockClient(
        (request) async => http.Response(jsonEncode(feed), 200),
      ),
    );

Map<String, Object?> _release(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  List<String> assets = const ['dfu_application.zip'],
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'html_url': 'https://example.test/$tag',
  'assets': [
    // A real firmware release also carries the SWD images and the partition
    // map; only the OTA package is installable from the app.
    {
      'name': 'merged.hex',
      'browser_download_url': 'https://example.test/$tag/merged.hex',
      'size': 900000,
    },
    for (final asset in assets)
      {
        'name': asset,
        'browser_download_url': 'https://example.test/$tag/$asset',
        'size': 440320,
        'digest': 'sha256:$_digest',
      },
  ],
};
