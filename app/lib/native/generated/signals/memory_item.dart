// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MemoryItem {
  const MemoryItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.body,
    required this.recordedAtMs,
    required this.evidenceIds,
  });

  static MemoryItem deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MemoryItem(
      kind: deserializer.deserializeString(),
      id: deserializer.deserializeString(),
      title: deserializer.deserializeString(),
      body: deserializer.deserializeString(),
      recordedAtMs: deserializer.deserializeInt64(),
      evidenceIds: TraitHelpers.deserializeVectorStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MemoryItem bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MemoryItem.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String kind;
  final String id;
  final String title;
  final String body;
  final int recordedAtMs;
  final List<String> evidenceIds;

  MemoryItem copyWith({
    String? kind,
    String? id,
    String? title,
    String? body,
    int? recordedAtMs,
    List<String>? evidenceIds,
  }) {
    return MemoryItem(
      kind: kind ?? this.kind,
      id: id ?? this.id,
      title: title ?? this.title,
      body: body ?? this.body,
      recordedAtMs: recordedAtMs ?? this.recordedAtMs,
      evidenceIds: evidenceIds ?? this.evidenceIds,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(kind);
    serializer.serializeString(id);
    serializer.serializeString(title);
    serializer.serializeString(body);
    serializer.serializeInt64(recordedAtMs);
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

    return other is MemoryItem &&
        kind == other.kind &&
        id == other.id &&
        title == other.title &&
        body == other.body &&
        recordedAtMs == other.recordedAtMs &&
        listEquals(evidenceIds, other.evidenceIds);
  }

  @override
  int get hashCode =>
      Object.hash(kind, id, title, body, recordedAtMs, evidenceIds);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'kind: $kind, '
          'id: $id, '
          'title: [REDACTED], '
          'body: [REDACTED], '
          'recordedAtMs: $recordedAtMs, '
          'evidenceIds: $evidenceIds'
          ')';
      return true;
    }());

    return fullString ?? 'MemoryItem';
  }
}
