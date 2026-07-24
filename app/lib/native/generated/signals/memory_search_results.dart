// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MemorySearchResults {
  const MemorySearchResults({
    required this.requestId,
    required this.query,
    required this.items,
    required this.gaps,
  });

  static MemorySearchResults deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MemorySearchResults(
      requestId: deserializer.deserializeString(),
      query: deserializer.deserializeString(),
      items: TraitHelpers.deserializeVectorMemorySearchItem(deserializer),
      gaps: TraitHelpers.deserializeVectorStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MemorySearchResults bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MemorySearchResults.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String query;
  final List<MemorySearchItem> items;
  final List<String> gaps;

  MemorySearchResults copyWith({
    String? requestId,
    String? query,
    List<MemorySearchItem>? items,
    List<String>? gaps,
  }) {
    return MemorySearchResults(
      requestId: requestId ?? this.requestId,
      query: query ?? this.query,
      items: items ?? this.items,
      gaps: gaps ?? this.gaps,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeString(query);
    TraitHelpers.serializeVectorMemorySearchItem(items, serializer);
    TraitHelpers.serializeVectorStr(gaps, serializer);
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

    return other is MemorySearchResults &&
        requestId == other.requestId &&
        query == other.query &&
        listEquals(items, other.items) &&
        listEquals(gaps, other.gaps);
  }

  @override
  int get hashCode => Object.hash(requestId, query, items, gaps);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'query: $query, '
          'items: $items, '
          'gaps: $gaps'
          ')';
      return true;
    }());

    return fullString ?? 'MemorySearchResults';
  }
}
