import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the mobile channel looks for its released builds. The default is the
/// repository's GitHub Releases API; a fork or a staging channel can point
/// somewhere else with `--dart-define=OMI_MOBILE_UPDATE_ENDPOINT=…` without
/// touching this file.
const mobileUpdateEndpoint = String.fromEnvironment(
  'OMI_MOBILE_UPDATE_ENDPOINT',
  defaultValue:
      'https://api.github.com/repos/undivisible/omi-v4/releases?per_page=30',
);

/// Mobile builds are published as their own `mobile-v*` releases alongside the
/// desktop ones in the same repository, so the tag prefix is what separates
/// the two channels.
const mobileReleaseTagPrefix = String.fromEnvironment(
  'OMI_MOBILE_RELEASE_TAG_PREFIX',
  defaultValue: 'mobile-v',
);

/// A released build newer than the one running.
final class MobileRelease {
  const MobileRelease({required this.version, required this.url});

  final String version;
  final String url;

  @override
  String toString() => 'MobileRelease($version, $url)';
}

/// Compares two dotted version strings. Missing components count as zero, and
/// anything non-numeric (a `+build` or `-beta` suffix) is ignored, so `1.2`
/// and `1.2.0+7` compare equal.
int compareVersions(String a, String b) {
  final left = _components(a);
  final right = _components(b);
  for (var index = 0; index < 3; index += 1) {
    final difference =
        (index < left.length ? left[index] : 0) -
        (index < right.length ? right[index] : 0);
    if (difference != 0) return difference.sign;
  }
  return 0;
}

List<int> _components(String version) {
  var text = version.trim();
  if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);
  final cut = text.indexOf(RegExp(r'[+\-]'));
  if (cut >= 0) text = text.substring(0, cut);
  return [for (final part in text.split('.')) int.tryParse(part.trim()) ?? 0];
}

/// Reads the release feed and reports a newer mobile build, if there is one.
///
/// Every failure mode — offline, DNS, a 404 from a channel that has not
/// published yet, malformed JSON — resolves to `null`. Nothing here is awaited
/// during app start, so a slow endpoint cannot delay the first frame.
final class MobileUpdateChecker {
  MobileUpdateChecker({
    this.client,
    this.currentVersion,
    String? endpoint,
    String? tagPrefix,
    Duration? timeout,
  }) : _endpoint = endpoint ?? mobileUpdateEndpoint,
       _tagPrefix = tagPrefix ?? mobileReleaseTagPrefix,
       _timeout = timeout ?? const Duration(seconds: 6);

  static const dismissedKey = 'mobile_update_dismissed_version_v1';

  /// Injected in tests; a fresh client is created and closed per check when
  /// this is null.
  final http.Client? client;

  /// Overrides the running version read from the app bundle, for tests.
  final String? currentVersion;

  final String _endpoint;
  final String _tagPrefix;
  final Duration _timeout;

  Future<MobileRelease?> check() async {
    final current = await _runningVersion();
    if (current == null) return null;
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
    final latest = _latest(response.body);
    if (latest == null) return null;
    if (compareVersions(latest.version, current) <= 0) return null;
    return await _dismissed() == latest.version ? null : latest;
  }

  /// Remembers that this exact version was waved away, so the prompt does not
  /// come back until something newer ships.
  Future<void> dismiss(MobileRelease release) async {
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

  Future<String?> _runningVersion() async {
    if (currentVersion case final value?) return value;
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return null;
    }
  }

  MobileRelease? _latest(String body) {
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
    MobileRelease? best;
    for (final entry in entries) {
      if (entry is! Map<String, Object?>) continue;
      if (entry['draft'] == true || entry['prerelease'] == true) continue;
      final tag = entry['tag_name'];
      if (tag is! String || !tag.startsWith(_tagPrefix)) continue;
      final version = tag.substring(_tagPrefix.length).trim();
      if (version.isEmpty) continue;
      final url = entry['html_url'];
      final release = MobileRelease(
        version: version,
        url: url is String && url.isNotEmpty
            ? url
            : 'https://github.com/undivisible/omi-v4/releases',
      );
      if (best == null || compareVersions(release.version, best.version) > 0) {
        best = release;
      }
    }
    return best;
  }
}
