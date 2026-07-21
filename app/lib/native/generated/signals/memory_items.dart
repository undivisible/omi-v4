// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MemoryItems {
  const MemoryItems({required this.requestId, required this.items});

  static MemoryItems deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MemoryItems(
      requestId: deserializer.deserializeString(),
      items: TraitHelpers.deserializeVectorMemoryItem(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MemoryItems bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MemoryItems.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final List<MemoryItem> items;

  MemoryItems copyWith({String? requestId, List<MemoryItem>? items}) {
    return MemoryItems(
      requestId: requestId ?? this.requestId,
      items: items ?? this.items,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    TraitHelpers.serializeVectorMemoryItem(items, serializer);
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

    return other is MemoryItems &&
        requestId == other.requestId &&
        listEquals(items, other.items);
  }

  @override
  int get hashCode => Object.hash(requestId, items);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'items: $items'
          ')';
      return true;
    }());

    return fullString ?? 'MemoryItems';
  }
}
