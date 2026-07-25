// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The answer to a [`Command::BeginCaptureSegment`]. `segment_id` is the
/// client-supplied idempotency key the transcription endpoint deduplicates on;
/// it is `None` exactly when `error` explains why no segment was opened.
@immutable
class CaptureSegmentBegun {
  const CaptureSegmentBegun({
    required this.requestId,
    this.segmentId,
    this.error,
  });

  static CaptureSegmentBegun deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CaptureSegmentBegun(
      requestId: deserializer.deserializeString(),
      segmentId: TraitHelpers.deserializeOptionStr(deserializer),
      error: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static CaptureSegmentBegun bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CaptureSegmentBegun.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String? segmentId;
  final String? error;

  CaptureSegmentBegun copyWith({
    String? requestId,
    String? Function()? segmentId,
    String? Function()? error,
  }) {
    return CaptureSegmentBegun(
      requestId: requestId ?? this.requestId,
      segmentId: segmentId == null ? this.segmentId : segmentId(),
      error: error == null ? this.error : error(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    TraitHelpers.serializeOptionStr(segmentId, serializer);
    TraitHelpers.serializeOptionStr(error, serializer);
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

    return other is CaptureSegmentBegun &&
        requestId == other.requestId &&
        segmentId == other.segmentId &&
        error == other.error;
  }

  @override
  int get hashCode => Object.hash(requestId, segmentId, error);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'segmentId: $segmentId, '
          'error: $error'
          ')';
      return true;
    }());

    return fullString ?? 'CaptureSegmentBegun';
  }
}
