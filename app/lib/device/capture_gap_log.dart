import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A recorded discontinuity in capture.
///
/// The evidence model requires every claim to carry a locator back to a real
/// time range, so a gap must be a first-class record: the audio either side of
/// it belongs to two different streams and must never be presented as one.
final class CaptureGapRecord {
  const CaptureGapRecord({
    required this.deviceId,
    required this.reason,
    required this.endedAt,
    required this.endedStreamId,
    this.resumedAt,
    this.resumedStreamId,
  });

  final String deviceId;

  /// The typed reason the previous session ended (a `DeviceAudioGapReason`
  /// name, or `sessionFailed` when the session died without a packet gap).
  final String reason;

  /// When the interrupted session stopped accepting audio.
  final DateTime endedAt;

  /// The stream id that ended. Segments carrying it are closed for good.
  final String endedStreamId;

  /// When capture resumed, or null while it has not.
  final DateTime? resumedAt;

  /// The new stream id capture resumed under. Always different from
  /// [endedStreamId]: a restart opens a new stream rather than continuing the
  /// old one, which is what makes the discontinuity impossible to re-splice.
  final String? resumedStreamId;

  /// How long capture was down, once it has come back.
  Duration? get duration => resumedAt?.difference(endedAt);

  CaptureGapRecord resumed({required DateTime at, required String streamId}) =>
      CaptureGapRecord(
        deviceId: deviceId,
        reason: reason,
        endedAt: endedAt,
        endedStreamId: endedStreamId,
        resumedAt: at,
        resumedStreamId: streamId,
      );

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'reason': reason,
    'endedAtMs': endedAt.toUtc().millisecondsSinceEpoch,
    'endedStreamId': endedStreamId,
    if (resumedAt != null)
      'resumedAtMs': resumedAt!.toUtc().millisecondsSinceEpoch,
    if (resumedStreamId != null) 'resumedStreamId': resumedStreamId,
  };

  static CaptureGapRecord? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final deviceId = value['deviceId'];
    final reason = value['reason'];
    final endedAtMs = value['endedAtMs'];
    final endedStreamId = value['endedStreamId'];
    if (deviceId is! String ||
        reason is! String ||
        endedAtMs is! int ||
        endedStreamId is! String) {
      return null;
    }
    final resumedAtMs = value['resumedAtMs'];
    final resumedStreamId = value['resumedStreamId'];
    return CaptureGapRecord(
      deviceId: deviceId,
      reason: reason,
      endedAt: DateTime.fromMillisecondsSinceEpoch(endedAtMs, isUtc: true),
      endedStreamId: endedStreamId,
      resumedAt: resumedAtMs is int
          ? DateTime.fromMillisecondsSinceEpoch(resumedAtMs, isUtc: true)
          : null,
      resumedStreamId: resumedStreamId is String ? resumedStreamId : null,
    );
  }
}

/// Where recorded discontinuities go. Recording must never fail the capture
/// path, so implementations swallow their own storage errors.
abstract interface class CaptureGapRecorder {
  Future<void> record(CaptureGapRecord gap);

  /// Attaches the resume side to the most recent open gap for [deviceId].
  Future<void> recordResume({
    required String deviceId,
    required DateTime at,
    required String streamId,
  });

  Future<List<CaptureGapRecord>> read();
}

/// Bounded, restart-surviving gap log in shared preferences.
final class PreferencesCaptureGapLog implements CaptureGapRecorder {
  PreferencesCaptureGapLog({this.limit = 100});

  static const _key = 'capture_gaps_v1';

  final int limit;

  @override
  Future<void> record(CaptureGapRecord gap) async {
    final gaps = await read();
    gaps.add(gap);
    await _write(gaps);
  }

  @override
  Future<void> recordResume({
    required String deviceId,
    required DateTime at,
    required String streamId,
  }) async {
    final gaps = await read();
    for (var index = gaps.length - 1; index >= 0; index--) {
      final gap = gaps[index];
      if (gap.deviceId == deviceId && gap.resumedAt == null) {
        gaps[index] = gap.resumed(at: at, streamId: streamId);
        await _write(gaps);
        return;
      }
    }
  }

  @override
  Future<List<CaptureGapRecord>> read() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getStringList(_key);
      if (raw == null) return [];
      return raw
          .map((entry) {
            try {
              return CaptureGapRecord.fromJson(jsonDecode(entry));
            } on FormatException {
              return null;
            }
          })
          .whereType<CaptureGapRecord>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _write(List<CaptureGapRecord> gaps) async {
    final trimmed = gaps.length > limit
        ? gaps.sublist(gaps.length - limit)
        : gaps;
    try {
      await (await SharedPreferences.getInstance()).setStringList(
        _key,
        trimmed.map((gap) => jsonEncode(gap.toJson())).toList(),
      );
    } catch (_) {}
  }
}

final class VolatileCaptureGapLog implements CaptureGapRecorder {
  final gaps = <CaptureGapRecord>[];

  @override
  Future<void> record(CaptureGapRecord gap) async => gaps.add(gap);

  @override
  Future<void> recordResume({
    required String deviceId,
    required DateTime at,
    required String streamId,
  }) async {
    for (var index = gaps.length - 1; index >= 0; index--) {
      final gap = gaps[index];
      if (gap.deviceId == deviceId && gap.resumedAt == null) {
        gaps[index] = gap.resumed(at: at, streamId: streamId);
        return;
      }
    }
  }

  @override
  Future<List<CaptureGapRecord>> read() async => List.of(gaps);
}
