// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MemorySearchItem {
  const MemorySearchItem({
    required this.kind,
    required this.id,
    required this.excerpt,
    required this.relevanceBasisPoints,
    required this.evidenceIds,
  });

  static MemorySearchItem deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MemorySearchItem(
      kind: deserializer.deserializeString(),
      id: deserializer.deserializeString(),
      excerpt: deserializer.deserializeString(),
      relevanceBasisPoints: deserializer.deserializeUint16(),
      evidenceIds: TraitHelpers.deserializeVectorStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MemorySearchItem bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MemorySearchItem.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String kind;
  final String id;
  final String excerpt;
  final int relevanceBasisPoints;
  final List<String> evidenceIds;

  MemorySearchItem copyWith({
    String? kind,
    String? id,
    String? excerpt,
    int? relevanceBasisPoints,
    List<String>? evidenceIds,
  }) {
    return MemorySearchItem(
      kind: kind ?? this.kind,
      id: id ?? this.id,
      excerpt: excerpt ?? this.excerpt,
      relevanceBasisPoints: relevanceBasisPoints ?? this.relevanceBasisPoints,
      evidenceIds: evidenceIds ?? this.evidenceIds,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(kind);
    serializer.serializeString(id);
    serializer.serializeString(excerpt);
    serializer.serializeUint16(relevanceBasisPoints);
    TraitHelpers.serializeVectorStr(evidenceIds, serializer);
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

    return other is MemorySearchItem &&
        kind == other.kind &&
        id == other.id &&
        excerpt == other.excerpt &&
        relevanceBasisPoints == other.relevanceBasisPoints &&
        listEquals(evidenceIds, other.evidenceIds);
  }

  @override
  int get hashCode =>
      Object.hash(kind, id, excerpt, relevanceBasisPoints, evidenceIds);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'kind: $kind, '
          'id: $id, '
          'excerpt: $excerpt, '
          'relevanceBasisPoints: $relevanceBasisPoints, '
          'evidenceIds: $evidenceIds'
          ')';
      return true;
    }());

    return fullString ?? 'MemorySearchItem';
  }
}
