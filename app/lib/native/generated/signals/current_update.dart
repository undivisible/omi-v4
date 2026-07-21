// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class CurrentUpdate {
  const CurrentUpdate({
    required this.currentId,
    required this.title,
    required this.summary,
    required this.updatedAtMs,
  });

  static CurrentUpdate deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CurrentUpdate(
      currentId: deserializer.deserializeString(),
      title: deserializer.deserializeString(),
      summary: deserializer.deserializeString(),
      updatedAtMs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static CurrentUpdate bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CurrentUpdate.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String currentId;
  final String title;
  final String summary;
  final int updatedAtMs;

  CurrentUpdate copyWith({
    String? currentId,
    String? title,
    String? summary,
    int? updatedAtMs,
  }) {
    return CurrentUpdate(
      currentId: currentId ?? this.currentId,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(currentId);
    serializer.serializeString(title);
    serializer.serializeString(summary);
    serializer.serializeInt64(updatedAtMs);
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

    return other is CurrentUpdate &&
        currentId == other.currentId &&
        title == other.title &&
        summary == other.summary &&
        updatedAtMs == other.updatedAtMs;
  }

  @override
  int get hashCode => Object.hash(currentId, title, summary, updatedAtMs);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'currentId: $currentId, '
          'title: $title, '
          'summary: $summary, '
          'updatedAtMs: $updatedAtMs'
          ')';
      return true;
    }());

    return fullString ?? 'CurrentUpdate';
  }
}
