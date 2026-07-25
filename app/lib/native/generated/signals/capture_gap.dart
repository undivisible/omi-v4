// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One recorded discontinuity in capture. The two stream ids are always
/// different: a restart opens a new stream rather than continuing the old one,
/// which is what makes the audio either side impossible to re-splice.
@immutable
class CaptureGap {
  const CaptureGap({
    required this.deviceId,
    required this.reason,
    required this.endedAtMs,
    required this.endedStreamId,
    this.resumedAtMs,
    this.resumedStreamId,
  });

  static CaptureGap deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CaptureGap(
      deviceId: deserializer.deserializeString(),
      reason: deserializer.deserializeString(),
      endedAtMs: deserializer.deserializeInt64(),
      endedStreamId: deserializer.deserializeString(),
      resumedAtMs: TraitHelpers.deserializeOptionI64(deserializer),
      resumedStreamId: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static CaptureGap bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CaptureGap.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String deviceId;
  final String reason;
  final int endedAtMs;
  final String endedStreamId;
  final int? resumedAtMs;
  final String? resumedStreamId;

  CaptureGap copyWith({
    String? deviceId,
    String? reason,
    int? endedAtMs,
    String? endedStreamId,
    int? Function()? resumedAtMs,
    String? Function()? resumedStreamId,
  }) {
    return CaptureGap(
      deviceId: deviceId ?? this.deviceId,
      reason: reason ?? this.reason,
      endedAtMs: endedAtMs ?? this.endedAtMs,
      endedStreamId: endedStreamId ?? this.endedStreamId,
      resumedAtMs: resumedAtMs == null ? this.resumedAtMs : resumedAtMs(),
      resumedStreamId: resumedStreamId == null
          ? this.resumedStreamId
          : resumedStreamId(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(deviceId);
    serializer.serializeString(reason);
    serializer.serializeInt64(endedAtMs);
    serializer.serializeString(endedStreamId);
    TraitHelpers.serializeOptionI64(resumedAtMs, serializer);
    TraitHelpers.serializeOptionStr(resumedStreamId, serializer);
    serializer.decreaseContainerDepth();
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CaptureGap &&
        deviceId == other.deviceId &&
        reason == other.reason &&
        endedAtMs == other.endedAtMs &&
        endedStreamId == other.endedStreamId &&
        resumedAtMs == other.resumedAtMs &&
        resumedStreamId == other.resumedStreamId;
  }

  @override
  int get hashCode => Object.hash(
    deviceId,
    reason,
    endedAtMs,
    endedStreamId,
    resumedAtMs,
    resumedStreamId,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'deviceId: $deviceId, '
          'reason: $reason, '
          'endedAtMs: $endedAtMs, '
          'endedStreamId: $endedStreamId, '
          'resumedAtMs: $resumedAtMs, '
          'resumedStreamId: $resumedStreamId'
          ')';
      return true;
    }());

    return fullString ?? 'CaptureGap';
  }
}
