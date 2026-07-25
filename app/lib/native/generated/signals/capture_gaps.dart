// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The answer to a [`Command::ReadCaptureGaps`], oldest first.
@immutable
class CaptureGaps {
  const CaptureGaps({required this.requestId, required this.gaps});

  static CaptureGaps deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CaptureGaps(
      requestId: deserializer.deserializeString(),
      gaps: TraitHelpers.deserializeVectorCaptureGap(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static CaptureGaps bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CaptureGaps.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final List<CaptureGap> gaps;

  CaptureGaps copyWith({String? requestId, List<CaptureGap>? gaps}) {
    return CaptureGaps(
      requestId: requestId ?? this.requestId,
      gaps: gaps ?? this.gaps,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    TraitHelpers.serializeVectorCaptureGap(gaps, serializer);
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

    return other is CaptureGaps &&
        requestId == other.requestId &&
        listEquals(gaps, other.gaps);
  }

  @override
  int get hashCode => Object.hash(requestId, gaps);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'gaps: $gaps'
          ')';
      return true;
    }());

    return fullString ?? 'CaptureGaps';
  }
}
