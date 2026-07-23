import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Deterministic Raycast-style fast path for the centered overlay: a bare
/// "open chrome" / "launch spotify" / "open github.com" resolves locally and
/// executes instantly, without a model round-trip. Anything that is not a
/// bare launch request falls through to the assistant as an agent
/// instruction.
sealed class LauncherIntent {
  const LauncherIntent();
}

/// A bare request to open an installed application by name. Resolution
/// against the installed-apps list happens natively (NSWorkspace); when no
/// app matches, the input still falls through to the assistant.
final class LaunchAppIntent extends LauncherIntent {
  const LaunchAppIntent(this.query);

  final String query;
}

/// A bare request to open a URL in the default browser.
final class OpenUrlIntent extends LauncherIntent {
  const OpenUrlIntent({required this.url, required this.display});

  final Uri url;

  /// Short human label for the "Opening …" flash (host, or the raw target).
  final String display;
}

final _launchVerbPattern = RegExp(
  r'^(?:open|launch)\s+(.+)$',
  caseSensitive: false,
);
final _explicitUrlPattern = RegExp(
  r'^https?://[^\s<>"]+$',
  caseSensitive: false,
);
final _bareDomainPattern = RegExp(
  r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+'
  r'(?:/[^\s]*)?$',
  caseSensitive: false,
);
final _appNamePattern = RegExp(
  r"^[a-z0-9][a-z0-9 .&+'\-]*$",
  caseSensitive: false,
);

/// Words that mark the target as a sentence or an object the launcher cannot
/// resolve deterministically ("open my tasks", "open the file and …"); those
/// inputs go to the assistant instead.
const _appStopWords = {
  'a',
  'an',
  'and',
  'for',
  'from',
  'in',
  'it',
  'me',
  'my',
  'of',
  'on',
  'or',
  'our',
  'that',
  'the',
  'this',
  'to',
  'up',
  'with',
  'your',
};

/// Parses a typed overlay submission into a deterministic launch intent, or
/// null when the input must go to the assistant. Deliberately conservative:
/// only bare "open/launch `<app>`" phrases (at most three plain words) and
/// URLs qualify; anything sentence-like falls through.
LauncherIntent? parseLauncherIntent(String input) {
  final normalized = input
      .replaceAll(RegExp(r'[.!?,]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return null;
  final urlIntent = _urlIntent(normalized);
  if (urlIntent != null) return urlIntent;
  final match = _launchVerbPattern.firstMatch(normalized);
  if (match == null) return null;
  final target = match.group(1)!.trim();
  final targetUrl = _urlIntent(target);
  if (targetUrl != null) return targetUrl;
  if (!_appNamePattern.hasMatch(target)) return null;
  final words = target.toLowerCase().split(' ');
  if (words.length > 3) return null;
  if (words.any(_appStopWords.contains)) return null;
  return LaunchAppIntent(target);
}

OpenUrlIntent? _urlIntent(String candidate) {
  if (_explicitUrlPattern.hasMatch(candidate)) {
    final url = Uri.tryParse(candidate);
    if (url == null) return null;
    return OpenUrlIntent(url: url, display: url.host);
  }
  if (!_bareDomainPattern.hasMatch(candidate)) return null;
  final url = Uri.tryParse('https://$candidate');
  if (url == null || url.host.isEmpty) return null;
  return OpenUrlIntent(url: url, display: url.host);
}

/// Opens an installed application by name through the Runner's NSWorkspace
/// bridge. Returns the resolved display name when the app was found and
/// launched, or null so the caller can fall through to the assistant.
final class OverlayAppLauncher {
  const OverlayAppLauncher({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('omi/launcher');

  final MethodChannel _channel;

  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  Future<String?> openApp(String query) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('openApp', query);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
