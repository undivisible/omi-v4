import 'dart:io';

import 'package:flutter/foundation.dart';

/// Dev-only direct Gemini access for running the app without an account.
///
/// The key is resolved, in order, from the `GEMINI_API_KEY` environment
/// variable, `~/.config/omi/dev.env`, `~/Library/Application Support/omi/dev.env`
/// (macOS), and `worker/.dev.vars` (also one directory up). The relative
/// `worker/.dev.vars` fallbacks only work when the app is launched from the
/// repository; apps opened from Finder/`open` start with `cwd=/` and an empty
/// shell environment, so once a key is found it is persisted to the stable
/// per-user location so later Finder launches keep working. Never logged.
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
    if (kIsWeb) {
      _cached = null;
    } else {
      _cached = resolve(environment: Platform.environment);
    }
    return _cached;
  }

  /// Stable per-user location that survives Finder/`open` launches (no shell
  /// environment, `cwd=/`). A key found anywhere else is copied here.
  @visibleForTesting
  static String? persistPath(Map<String, String> environment) {
    final home = environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return !kIsWeb && Platform.isMacOS
        ? '$home/Library/Application Support/omi/dev.env'
        : '$home/.config/omi/dev.env';
  }

  @visibleForTesting
  static List<String> candidatePaths(
    Map<String, String> environment, {
    String workingDirectory = '.',
  }) {
    final home = environment['HOME'];
    final stable = persistPath(environment);
    return [
      if (home != null && home.isNotEmpty) '$home/.config/omi/dev.env',
      ?stable,
      '$workingDirectory/worker/.dev.vars',
      '$workingDirectory/../worker/.dev.vars',
    ];
  }

  @visibleForTesting
  static String? resolve({
    required Map<String, String> environment,
    String workingDirectory = '.',
    bool persist = true,
  }) {
    String? found;
    final fromEnvironment = _valid(environment['GEMINI_API_KEY']);
    if (fromEnvironment != null) {
      found = fromEnvironment;
    } else {
      for (final path in candidatePaths(
        environment,
        workingDirectory: workingDirectory,
      )) {
        final value = _fromEnvFile(path);
        if (value != null) {
          found = value;
          break;
        }
      }
    }
    if (found != null && persist) {
      _persist(found, environment);
    }
    return found;
  }

  static void _persist(String key, Map<String, String> environment) {
    final path = persistPath(environment);
    if (path == null) return;
    if (_fromEnvFile(path) == key) return;
    try {
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync('GEMINI_API_KEY=$key\n');
    } on FileSystemException {
      return;
    }
  }

  /// Where a key may be placed, for actionable error messages. Never includes
  /// key material.
  static String get missingKeyHint {
    final paths = candidatePaths(
      kIsWeb ? const {} : Platform.environment,
    ).join(', ');
    return 'No developer Gemini key found. Set GEMINI_API_KEY in one of: '
        '$paths — then relaunch Omi.';
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
