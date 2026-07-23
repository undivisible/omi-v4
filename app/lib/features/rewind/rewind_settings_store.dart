import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../storage/omi_directory.dart';
import 'rewind_models.dart';
import 'rewind_privacy.dart';

/// Everything the user has decided about Rewind. Recording is opt-in: the
/// default is off, and it stays off until the user turns it on in settings.
@immutable
final class RewindSettings {
  const RewindSettings({
    this.enabled = false,
    this.paused = false,
    this.retention = const RewindRetention(),
    this.privacy = const RewindPrivacySettings(),
  });

  /// Master switch. Off by default — continuous screen capture is never
  /// something the app starts doing on its own.
  final bool enabled;

  /// The one-click pause. Distinct from [enabled] so pausing does not lose
  /// the configuration, and so the indicator can say "paused" rather than
  /// vanishing.
  final bool paused;

  final RewindRetention retention;
  final RewindPrivacySettings privacy;

  bool get recording => enabled && !paused;

  RewindSettings copyWith({
    bool? enabled,
    bool? paused,
    RewindRetention? retention,
    RewindPrivacySettings? privacy,
  }) => RewindSettings(
    enabled: enabled ?? this.enabled,
    paused: paused ?? this.paused,
    retention: retention ?? this.retention,
    privacy: privacy ?? this.privacy,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'paused': paused,
    'retention': retention.toJson(),
    'privacy': privacy.toJson(),
  };

  static RewindSettings fromJson(Object? value) {
    if (value is! Map) return const RewindSettings();
    return RewindSettings(
      enabled: value['enabled'] as bool? ?? false,
      paused: value['paused'] as bool? ?? false,
      retention: RewindRetention.fromJson(value['retention']),
      privacy: RewindPrivacySettings.fromJson(value['privacy']),
    );
  }
}

abstract interface class RewindSettingsStore {
  Future<RewindSettings> read();
  Future<void> write(RewindSettings settings);
}

/// Rewind's settings live in a file rather than in shared preferences on
/// purpose: the macOS settings window is a second Flutter engine with its own
/// isolate and its own preference cache, so a toggle flipped there has to be
/// visible to the engine that is actually capturing. A file is the one place
/// both can see.
final class FileRewindSettingsStore implements RewindSettingsStore {
  FileRewindSettingsStore([this._file]);

  File? _file;

  Future<File> _resolve() async {
    final existing = _file;
    if (existing != null) return existing;
    final base = await omiDataDirectory();
    final directory = Directory('${base.path}${Platform.pathSeparator}rewind');
    await directory.create(recursive: true);
    return _file = File(
      '${directory.path}${Platform.pathSeparator}settings.json',
    );
  }

  /// The modification time the caller last saw, so a polling reader can skip
  /// the decode when nothing has changed.
  Future<DateTime?> lastModified() async {
    final file = await _resolve();
    try {
      return await file.exists() ? await file.lastModified() : null;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<RewindSettings> read() async {
    final file = await _resolve();
    try {
      if (!await file.exists()) return const RewindSettings();
      return RewindSettings.fromJson(jsonDecode(await file.readAsString()));
    } on FormatException {
      return const RewindSettings();
    } on FileSystemException {
      return const RewindSettings();
    }
  }

  @override
  Future<void> write(RewindSettings settings) async {
    final file = await _resolve();
    await file.writeAsString(jsonEncode(settings.toJson()), flush: true);
  }
}

final class VolatileRewindSettingsStore implements RewindSettingsStore {
  RewindSettings value = const RewindSettings();

  @override
  Future<RewindSettings> read() async => value;

  @override
  Future<void> write(RewindSettings settings) async => value = settings;
}
