// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MemorySourceDeleted {
  const MemorySourceDeleted({
    required this.requestId,
    required this.sourceId,
    required this.evidenceCount,
    required this.claimCount,
  });

  static MemorySourceDeleted deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MemorySourceDeleted(
      requestId: deserializer.deserializeString(),
      sourceId: deserializer.deserializeString(),
      evidenceCount: deserializer.deserializeUint64(),
      claimCount: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MemorySourceDeleted bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MemorySourceDeleted.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String sourceId;
  final Uint64 evidenceCount;
  final Uint64 claimCount;

  MemorySourceDeleted copyWith({
    String? requestId,
    String? sourceId,
    Uint64? evidenceCount,
    Uint64? claimCount,
  }) {
    return MemorySourceDeleted(
      requestId: requestId ?? this.requestId,
      sourceId: sourceId ?? this.sourceId,
      evidenceCount: evidenceCount ?? this.evidenceCount,
      claimCount: claimCount ?? this.claimCount,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeString(sourceId);
    serializer.serializeUint64(evidenceCount);
    serializer.serializeUint64(claimCount);
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

    return other is MemorySourceDeleted &&
        requestId == other.requestId &&
        sourceId == other.sourceId &&
        evidenceCount == other.evidenceCount &&
        claimCount == other.claimCount;
  }

  @override
  int get hashCode =>
      Object.hash(requestId, sourceId, evidenceCount, claimCount);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'sourceId: $sourceId, '
          'evidenceCount: $evidenceCount, '
          'claimCount: $claimCount'
          ')';
      return true;
    }());

    return fullString ?? 'MemorySourceDeleted';
  }
}
