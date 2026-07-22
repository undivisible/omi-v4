import 'dart:io';

import 'package:flutter/foundation.dart';

/// Dev-only direct Gemini access for running the app without an account.
///
/// The key is resolved, in order, from the `GEMINI_API_KEY` environment
/// variable, `~/.config/omi/dev.env`, and `worker/.dev.vars` (also one
/// directory up). Never logged, never persisted by the app.
abstract final class DevGemini {
  static const liveModel = 'gemini-3.1-flash-live-preview';

  static String? _cached;
  static bool _resolved = false;

  @visibleForTesting
  static set debugOverride(String? value) {
    _cached = value;
    _resolved = true;
  }

  static String? get apiKey {
    if (_resolved) return _cached;
    _resolved = true;
    _cached = _resolve();
    return _cached;
  }

  static String? _resolve() {
    if (kIsWeb) return null;
    final fromEnvironment = _valid(Platform.environment['GEMINI_API_KEY']);
    if (fromEnvironment != null) return fromEnvironment;
    final home = Platform.environment['HOME'];
    final candidates = [
      if (home != null && home.isNotEmpty) '$home/.config/omi/dev.env',
      'worker/.dev.vars',
      '../worker/.dev.vars',
    ];
    for (final path in candidates) {
      final value = _fromEnvFile(path);
      if (value != null) return value;
    }
    return null;
  }

  static String? _fromEnvFile(String path) {
    final String contents;
    try {
      contents = File(path).readAsStringSync();
    } on FileSystemException {
      return null;
    }
    for (final line in contents.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('#')) continue;
      final separator = trimmed.indexOf('=');
      if (separator <= 0) continue;
      if (trimmed.substring(0, separator).trim() != 'GEMINI_API_KEY') continue;
      final raw = trimmed.substring(separator + 1).trim();
      final value = _valid(
        raw.length >= 2 &&
                ((raw.startsWith('"') && raw.endsWith('"')) ||
                    (raw.startsWith("'") && raw.endsWith("'")))
            ? raw.substring(1, raw.length - 1)
            : raw,
      );
      if (value != null) return value;
    }
    return null;
  }

  static String? _valid(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null ||
        trimmed.isEmpty ||
        trimmed.length > 256 ||
        trimmed.contains('your-') ||
        trimmed.contains(' ')) {
      return null;
    }
    return trimmed;
  }
}
