// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class MemoryApplied {
  const MemoryApplied({
    required this.requestId,
    required this.commitsApplied,
    required this.commitsSkipped,
    required this.recordsApplied,
    required this.recordsSkipped,
  });

  static MemoryApplied deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MemoryApplied(
      requestId: deserializer.deserializeString(),
      commitsApplied: deserializer.deserializeUint64(),
      commitsSkipped: deserializer.deserializeUint64(),
      recordsApplied: deserializer.deserializeUint64(),
      recordsSkipped: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MemoryApplied bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MemoryApplied.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final Uint64 commitsApplied;
  final Uint64 commitsSkipped;
  final Uint64 recordsApplied;
  final Uint64 recordsSkipped;

  MemoryApplied copyWith({
    String? requestId,
    Uint64? commitsApplied,
    Uint64? commitsSkipped,
    Uint64? recordsApplied,
    Uint64? recordsSkipped,
  }) {
    return MemoryApplied(
      requestId: requestId ?? this.requestId,
      commitsApplied: commitsApplied ?? this.commitsApplied,
      commitsSkipped: commitsSkipped ?? this.commitsSkipped,
      recordsApplied: recordsApplied ?? this.recordsApplied,
      recordsSkipped: recordsSkipped ?? this.recordsSkipped,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeUint64(commitsApplied);
    serializer.serializeUint64(commitsSkipped);
    serializer.serializeUint64(recordsApplied);
    serializer.serializeUint64(recordsSkipped);
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

    return other is MemoryApplied
      && requestId == other.requestId
      && commitsApplied == other.commitsApplied
      && commitsSkipped == other.commitsSkipped
      && recordsApplied == other.recordsApplied
      && recordsSkipped == other.recordsSkipped;
  }

  @override
  int get hashCode => Object.hash(
        requestId,
        commitsApplied,
        commitsSkipped,
        recordsApplied,
        recordsSkipped,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'requestId: $requestId, '
        'commitsApplied: $commitsApplied, '
        'commitsSkipped: $commitsSkipped, '
        'recordsApplied: $recordsApplied, '
        'recordsSkipped: $recordsSkipped'
        ')';
      return true;
    }());

    return fullString ?? 'MemoryApplied';
  }
}
