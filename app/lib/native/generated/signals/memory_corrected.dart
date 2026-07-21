// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MemoryCorrected {
  const MemoryCorrected({
    required this.requestId,
    required this.sourceId,
    required this.evidenceId,
    required this.claimId,
    required this.supersededClaimId,
  });

  static MemoryCorrected deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MemoryCorrected(
      requestId: deserializer.deserializeString(),
      sourceId: deserializer.deserializeString(),
      evidenceId: deserializer.deserializeString(),
      claimId: deserializer.deserializeString(),
      supersededClaimId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MemoryCorrected bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MemoryCorrected.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String sourceId;
  final String evidenceId;
  final String claimId;
  final String supersededClaimId;

  MemoryCorrected copyWith({
    String? requestId,
    String? sourceId,
    String? evidenceId,
    String? claimId,
    String? supersededClaimId,
  }) {
    return MemoryCorrected(
      requestId: requestId ?? this.requestId,
      sourceId: sourceId ?? this.sourceId,
      evidenceId: evidenceId ?? this.evidenceId,
      claimId: claimId ?? this.claimId,
      supersededClaimId: supersededClaimId ?? this.supersededClaimId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeString(sourceId);
    serializer.serializeString(evidenceId);
    serializer.serializeString(claimId);
    serializer.serializeString(supersededClaimId);
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

    return other is MemoryCorrected &&
        requestId == other.requestId &&
        sourceId == other.sourceId &&
        evidenceId == other.evidenceId &&
        claimId == other.claimId &&
        supersededClaimId == other.supersededClaimId;
  }

  @override
  int get hashCode =>
      Object.hash(requestId, sourceId, evidenceId, claimId, supersededClaimId);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'sourceId: $sourceId, '
          'evidenceId: $evidenceId, '
          'claimId: $claimId, '
          'supersededClaimId: $supersededClaimId'
          ')';
      return true;
    }());

    return fullString ?? 'MemoryCorrected';
  }
}
