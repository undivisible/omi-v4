import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mobile_update_check.dart' show compareVersions;

/// Where the pendant firmware channel looks for its releases. Same repository
/// and same shape as the mobile app channel — only the tag prefix separates
/// them — so a fork or a staging channel can repoint it without touching this
/// file.
const firmwareUpdateEndpoint = String.fromEnvironment(
  'OMI_FIRMWARE_UPDATE_ENDPOINT',
  defaultValue:
      'https://api.github.com/repos/undivisible/omi-v4/releases?per_page=30',
);

/// Firmware is published as its own `firmware-v*` releases alongside the app
/// ones (see `firmware/README.md`).
const firmwareReleaseTagPrefix = String.fromEnvironment(
  'OMI_FIRMWARE_RELEASE_TAG_PREFIX',
  defaultValue: 'firmware-v',
);

/// The OTA package name the firmware build emits per target
/// (`firmware/README.md`, "Outputs in omi/build/"). Release assets are matched
/// on this so a release carrying `merged.hex` and `partitions.yml` alongside it
/// still resolves to the one artifact DFU can consume.
const firmwareArtifactMarker = 'dfu_application';

/// A published firmware build and the OTA package that goes with it.
final class FirmwareRelease {
  const FirmwareRelease({
    required this.version,
    required this.url,
    required this.assetName,
    required this.assetUrl,
    this.sizeBytes,
    this.digest,
  });

  final String version;

  /// The human-readable release page, for the "read the notes" and
  /// "flash it yourself" escape hatches.
  final String url;
  final String assetName;
  final String assetUrl;
  final int? sizeBytes;

  /// The asset digest GitHub publishes alongside the size, in its
  /// `<algorithm>:<hex>` form (`sha256:…`). Null on a release old enough — or a
  /// mirror plain enough — not to carry one; the size check still applies.
  final String? digest;

  @override
  String toString() => 'FirmwareRelease($version, $assetName)';
}

/// Why an update cannot be installed right now. Everything except
/// [FirmwareUpdateBlock.none] is a reason to keep the install control out of
/// reach — [unsupported] hides the affordance entirely rather than letting
/// someone walk to the end of a flow that cannot finish.
enum FirmwareUpdateBlock {
  none,
  disconnected,
  unsupported,
  lowBattery,
  capturing,
}

/// Below this the pendant may not survive a swap-and-verify cycle, and MCUboot
/// is configured overwrite-only, so a failed boot has no image to fall back to.
const firmwareUpdateMinimumBattery = 40;

/// Decides whether a DFU may start. Pure so the rule is testable without a
/// pendant, a download, or a BLE stack.
FirmwareUpdateBlock firmwareUpdateBlock({
  required bool connected,
  required bool dfuSupported,
  required bool capturing,
  required int? batteryLevel,
}) {
  if (!connected) return FirmwareUpdateBlock.disconnected;
  if (!dfuSupported) return FirmwareUpdateBlock.unsupported;
  if (batteryLevel != null && batteryLevel < firmwareUpdateMinimumBattery) {
    return FirmwareUpdateBlock.lowBattery;
  }
  if (capturing) return FirmwareUpdateBlock.capturing;
  return FirmwareUpdateBlock.none;
}

/// The subset of [firmwareUpdateBlock] that still applies once an install is
/// under way. The link is deliberately handed to the DFU transport partway
/// through, so "disconnected" stops meaning anything — but a capture the user
/// restarted, or a battery that fell below the floor, are still reasons to stop
/// before the upload completes and MCUboot swaps.
FirmwareUpdateBlock firmwareUpdateAbort({
  required bool capturing,
  required int? batteryLevel,
}) {
  if (batteryLevel != null && batteryLevel < firmwareUpdateMinimumBattery) {
    return FirmwareUpdateBlock.lowBattery;
  }
  if (capturing) return FirmwareUpdateBlock.capturing;
  return FirmwareUpdateBlock.none;
}

/// Reads the release feed and reports a firmware build newer than the one the
/// connected pendant reports over the Device Information Service (`0x2A26`).
///
/// Every failure mode — offline, a channel that has published nothing, a
/// release with no OTA package attached, a pendant that does not report its
/// revision — resolves to `null`. Nothing here blocks a frame.
final class FirmwareUpdateChecker {
  FirmwareUpdateChecker({
    this.client,
    String? endpoint,
    String? tagPrefix,
    Duration? timeout,
  }) : _endpoint = endpoint ?? firmwareUpdateEndpoint,
       _tagPrefix = tagPrefix ?? firmwareReleaseTagPrefix,
       _timeout = timeout ?? const Duration(seconds: 6);

  static const dismissedKey = 'firmware_update_dismissed_version_v1';

  /// Injected in tests; a fresh client is created and closed per check when
  /// this is null.
  final http.Client? client;

  final String _endpoint;
  final String _tagPrefix;
  final Duration _timeout;

  /// [installedRevision] is the DIS firmware revision string. [target] is the
  /// build target id (`omi-cv1`, `devkit-v1`…) when the release publishes one
  /// artifact per target; a release with a single OTA package matches anyway.
  Future<FirmwareRelease?> check({
    required String? installedRevision,
    String? target,
  }) async {
    final installed = installedRevision?.trim();
    if (installed == null || installed.isEmpty) return null;
    final uri = Uri.tryParse(_endpoint);
    if (uri == null || !uri.hasScheme) return null;
    final httpClient = client ?? http.Client();
    http.Response response;
    try {
      response = await httpClient
          .get(uri, headers: const {'Accept': 'application/vnd.github+json'})
          .timeout(_timeout);
    } catch (_) {
      return null;
    } finally {
      if (client == null) httpClient.close();
    }
    if (response.statusCode != 200) return null;
    final latest = _latest(response.body, target);
    if (latest == null) return null;
    if (compareVersions(latest.version, installed) <= 0) return null;
    return await _dismissed() == latest.version ? null : latest;
  }

  /// Remembers that this exact firmware version was waved away.
  Future<void> dismiss(FirmwareRelease release) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        dismissedKey,
        release.version,
      );
    } catch (_) {}
  }

  Future<String?> _dismissed() async {
    try {
      return (await SharedPreferences.getInstance()).getString(dismissedKey);
    } catch (_) {
      return null;
    }
  }

  FirmwareRelease? _latest(String body, String? target) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    final entries = switch (decoded) {
      final List<Object?> list => list,
      final Map<String, Object?> single => [single],
      _ => const <Object?>[],
    };
    FirmwareRelease? best;
    for (final entry in entries) {
      if (entry is! Map<String, Object?>) continue;
      if (entry['draft'] == true || entry['prerelease'] == true) continue;
      final tag = entry['tag_name'];
      if (tag is! String || !tag.startsWith(_tagPrefix)) continue;
      final version = tag.substring(_tagPrefix.length).trim();
      if (version.isEmpty) continue;
      final asset = _artifact(entry['assets'], target);
      // A release with no OTA package cannot be installed from the app, so it
      // is not an update as far as this checker is concerned.
      if (asset == null) continue;
      final url = entry['html_url'];
      final release = FirmwareRelease(
        version: version,
        url: url is String && url.isNotEmpty
            ? url
            : 'https://github.com/undivisible/omi-v4/releases',
        assetName: asset.name,
        assetUrl: asset.url,
        sizeBytes: asset.size,
        digest: asset.digest,
      );
      if (best == null || compareVersions(release.version, best.version) > 0) {
        best = release;
      }
    }
    return best;
  }

  ({String name, String url, int? size, String? digest})? _artifact(
    Object? assets,
    String? target,
  ) {
    if (assets is! List<Object?>) return null;
    final candidates =
        <({String name, String url, int? size, String? digest})>[];
    for (final asset in assets) {
      if (asset is! Map<String, Object?>) continue;
      final name = asset['name'];
      final url = asset['browser_download_url'];
      if (name is! String || url is! String) continue;
      if (!name.toLowerCase().contains(firmwareArtifactMarker)) continue;
      final size = asset['size'];
      final digest = asset['digest'];
      candidates.add((
        name: name,
        url: url,
        size: size is int ? size : null,
        digest: digest is String && digest.isNotEmpty ? digest : null,
      ));
    }
    if (target != null) {
      // The DIS model number the pendant reports (`Omi CV 1`) and the artifact
      // id the release names it by (`omi-cv1-production-nrf5340-pendant`) spell
      // the same target with different separators and spacing, so normalise both
      // to alphanumerics before matching — a literal substring check misses.
      final hint = _normalizeTarget(target);
      if (hint.isNotEmpty) {
        for (final candidate in candidates) {
          if (_normalizeTarget(candidate.name).contains(hint)) return candidate;
        }
      }
    }
    // A release that publishes one package per target and gave no usable hint
    // is ambiguous, and picking the wrong image is how a pendant gets bricked.
    return candidates.length == 1 ? candidates.single : null;
  }

  static String _normalizeTarget(String value) =>
      value.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
}

/// Fetches a firmware artifact. Kept separate from the flash itself: a download
/// is reversible and a flash is not, and a widget test wants the screen without
/// the network or the disk.
abstract interface class FirmwareDownloader {
  Future<File> download(
    FirmwareRelease release, {
    void Function(double progress)? onProgress,
  });
}

/// Streams the artifact to a file, reporting progress as it goes.
final class HttpFirmwareDownloader implements FirmwareDownloader {
  HttpFirmwareDownloader({this.client, this.directory});

  final http.Client? client;

  /// Where the artifact lands. Defaults to the app's temporary directory, so
  /// an abandoned download is not kept forever.
  final Directory? directory;

  @override
  Future<File> download(
    FirmwareRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    final target = directory ?? await getTemporaryDirectory();
    final file = File('${target.path}/omi-firmware-${release.version}.zip');
    final httpClient = client ?? http.Client();
    try {
      final request = http.Request('GET', Uri.parse(release.assetUrl));
      request.headers['Accept'] = 'application/octet-stream';
      final response = await httpClient.send(request);
      if (response.statusCode != 200) {
        throw HttpException(
          'Firmware download failed with ${response.statusCode}',
          uri: Uri.parse(release.assetUrl),
        );
      }
      final total = response.contentLength ?? release.sizeBytes;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total != null && total > 0) {
            onProgress?.call((received / total).clamp(0.0, 1.0));
          }
        }
      } finally {
        await sink.close();
      }
      onProgress?.call(1);
      return file;
    } finally {
      if (client == null) httpClient.close();
    }
  }
}
