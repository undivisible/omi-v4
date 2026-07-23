import 'package:flutter/foundation.dart';

/// What Omi knows about the screen at the instant the policy is asked whether
/// to capture. Deliberately tiny: the frontmost app, its bundle id, and the
/// window title. Nothing here is stored unless a frame is stored.
@immutable
final class RewindWindowContext {
  const RewindWindowContext({this.bundleId, this.appName, this.windowTitle});

  final String? bundleId;
  final String? appName;
  final String? windowTitle;

  static const unknown = RewindWindowContext();

  /// Two contexts are the "same screen" for heartbeat purposes when the app
  /// and the window title both match. A title change (new tab, new document)
  /// is a context change and earns an immediate capture.
  bool sameAs(RewindWindowContext other) =>
      bundleId == other.bundleId &&
      appName == other.appName &&
      windowTitle == other.windowTitle;

  static RewindWindowContext fromMap(Object? value) {
    if (value is! Map) return unknown;
    String? field(String key) {
      final raw = value[key];
      if (raw is! String) return null;
      final trimmed = raw.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    return RewindWindowContext(
      bundleId: field('bundleId'),
      appName: field('appName'),
      windowTitle: field('windowTitle'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RewindWindowContext && sameAs(other);

  @override
  int get hashCode => Object.hash(bundleId, appName, windowTitle);
}

/// How often an app is worth looking at. Slow-changing surfaces (a paused
/// video, an album cover, a page of a book) do not repay a fast heartbeat, and
/// capturing them at the interactive rate is what makes naive continuous
/// capture eat battery and disk.
enum RewindAppTempo { interactive, slowChanging }

/// The knobs behind the capture policy. Every duration is a policy decision,
/// not an implementation detail, so they live in one place and tests can pin
/// them.
@immutable
final class RewindPolicyConfig {
  const RewindPolicyConfig({
    this.interactiveHeartbeat = const Duration(seconds: 20),
    this.slowChangingHeartbeat = const Duration(minutes: 3),
    this.idleAfter = const Duration(minutes: 2),
    this.minimumInterval = const Duration(seconds: 3),
    this.similarityThreshold = 3,
  });

  /// Heartbeat for an ordinary app the user is working in.
  final Duration interactiveHeartbeat;

  /// Heartbeat for apps classified [RewindAppTempo.slowChanging].
  final Duration slowChangingHeartbeat;

  /// No input for this long means the user is not at the machine; the
  /// heartbeat stops entirely until input returns.
  final Duration idleAfter;

  /// A floor under the capture rate, so a burst of context changes (rapid
  /// window switching) cannot turn into a burst of full-frame captures.
  final Duration minimumInterval;

  /// Maximum Hamming distance between consecutive preview hashes that still
  /// counts as "the screen did not meaningfully change".
  final int similarityThreshold;

  Duration heartbeatFor(RewindAppTempo tempo) => switch (tempo) {
    RewindAppTempo.interactive => interactiveHeartbeat,
    RewindAppTempo.slowChanging => slowChangingHeartbeat,
  };
}

/// How long frames live and how much disk they may occupy. Both bounds are
/// enforced on every write, oldest-first, and both are user-visible.
@immutable
final class RewindRetention {
  const RewindRetention({
    this.maxAge = const Duration(days: 14),
    this.maxBytes = 4 * 1024 * 1024 * 1024,
  });

  final Duration maxAge;
  final int maxBytes;

  static const options = <RewindRetention>[
    RewindRetention(maxAge: Duration(days: 1), maxBytes: 512 * 1024 * 1024),
    RewindRetention(
      maxAge: Duration(days: 7),
      maxBytes: 2 * 1024 * 1024 * 1024,
    ),
    RewindRetention(
      maxAge: Duration(days: 14),
      maxBytes: 4 * 1024 * 1024 * 1024,
    ),
    RewindRetention(
      maxAge: Duration(days: 30),
      maxBytes: 8 * 1024 * 1024 * 1024,
    ),
  ];

  String get label {
    final days = maxAge.inDays;
    final gigabytes = maxBytes / (1024 * 1024 * 1024);
    final size = gigabytes >= 1
        ? '${gigabytes.toStringAsFixed(gigabytes == gigabytes.roundToDouble() ? 0 : 1)} GB'
        : '${(maxBytes / (1024 * 1024)).round()} MB';
    return '$days ${days == 1 ? 'day' : 'days'} · $size';
  }

  Map<String, Object?> toJson() => {
    'maxAgeDays': maxAge.inDays,
    'maxBytes': maxBytes,
  };

  static RewindRetention fromJson(Object? value) {
    if (value is! Map) return const RewindRetention();
    final days = value['maxAgeDays'];
    final bytes = value['maxBytes'];
    if (days is! int || days <= 0 || bytes is! int || bytes <= 0) {
      return const RewindRetention();
    }
    return RewindRetention(
      maxAge: Duration(days: days),
      maxBytes: bytes,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RewindRetention &&
      other.maxAge == maxAge &&
      other.maxBytes == maxBytes;

  @override
  int get hashCode => Object.hash(maxAge, maxBytes);
}

/// One stored screenshot, as recorded in the on-disk index.
@immutable
final class RewindFrame {
  const RewindFrame({
    required this.capturedAt,
    required this.relativePath,
    required this.bytes,
    required this.hash,
    this.appName,
    this.bundleId,
    this.windowTitle,
    this.ocrText,
  });

  final DateTime capturedAt;
  final String relativePath;
  final int bytes;

  /// The 64-bit dHash of the preview this frame was accepted from, as hex.
  final String hash;

  final String? appName;
  final String? bundleId;
  final String? windowTitle;

  /// Text read off this frame by Apple's Vision framework, on-device. This is
  /// what search and any downstream model actually reads — the image itself
  /// never leaves the machine.
  final String? ocrText;

  Map<String, Object?> toJson() => {
    'at': capturedAt.toUtc().toIso8601String(),
    'path': relativePath,
    'bytes': bytes,
    'hash': hash,
    if (appName != null) 'app': appName,
    if (bundleId != null) 'bundleId': bundleId,
    if (windowTitle != null) 'title': windowTitle,
    if (ocrText != null) 'text': ocrText,
  };

  static RewindFrame? fromJson(Object? value) {
    if (value is! Map) return null;
    final at = DateTime.tryParse(value['at'] as String? ?? '');
    final path = value['path'];
    final bytes = value['bytes'];
    final hash = value['hash'];
    if (at == null ||
        path is! String ||
        path.isEmpty ||
        bytes is! int ||
        bytes < 0 ||
        hash is! String) {
      return null;
    }
    return RewindFrame(
      capturedAt: at.toLocal(),
      relativePath: path,
      bytes: bytes,
      hash: hash,
      appName: value['app'] as String?,
      bundleId: value['bundleId'] as String?,
      windowTitle: value['title'] as String?,
      ocrText: value['text'] as String?,
    );
  }
}
