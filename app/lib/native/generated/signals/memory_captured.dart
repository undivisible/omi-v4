// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MemoryCaptured {
  const MemoryCaptured({
    required this.requestId,
    required this.sourceId,
    required this.evidenceId,
  });

  static MemoryCaptured deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MemoryCaptured(
      requestId: deserializer.deserializeString(),
      sourceId: deserializer.deserializeString(),
      evidenceId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MemoryCaptured bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MemoryCaptured.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String sourceId;
  final String evidenceId;

  MemoryCaptured copyWith({
    String? requestId,
    String? sourceId,
    String? evidenceId,
  }) {
    return MemoryCaptured(
      requestId: requestId ?? this.requestId,
      sourceId: sourceId ?? this.sourceId,
      evidenceId: evidenceId ?? this.evidenceId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeString(sourceId);
    serializer.serializeString(evidenceId);
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

    return other is MemoryCaptured &&
        requestId == other.requestId &&
        sourceId == other.sourceId &&
        evidenceId == other.evidenceId;
  }

  @override
  int get hashCode => Object.hash(requestId, sourceId, evidenceId);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'sourceId: $sourceId, '
          'evidenceId: $evidenceId'
          ')';
      return true;
    }());

    return fullString ?? 'MemoryCaptured';
  }
}
