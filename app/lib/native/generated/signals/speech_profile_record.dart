// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One profile, as the settings list needs it.
///
/// Voiceprints are deliberately absent. They are the one thing in this module
/// that must never leave the device, and a signal is a bridge to code the hub
/// does not control — so the count is published and the vectors are not.
@immutable
class SpeechProfileRecord {
  const SpeechProfileRecord({
    required this.id,
    required this.kind,
    this.displayName,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.learningPaused,
    required this.embeddingCount,
  });

  static SpeechProfileRecord deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = SpeechProfileRecord(
      id: deserializer.deserializeString(),
      kind: deserializer.deserializeString(),
      displayName: TraitHelpers.deserializeOptionStr(deserializer),
      createdAtMs: deserializer.deserializeInt64(),
      updatedAtMs: deserializer.deserializeInt64(),
      learningPaused: deserializer.deserializeBool(),
      embeddingCount: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static SpeechProfileRecord bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SpeechProfileRecord.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String id;
  final String kind;
  final String? displayName;
  final int createdAtMs;
  final int updatedAtMs;
  final bool learningPaused;
  final int embeddingCount;

  SpeechProfileRecord copyWith({
    String? id,
    String? kind,
    String? Function()? displayName,
    int? createdAtMs,
    int? updatedAtMs,
    bool? learningPaused,
    int? embeddingCount,
  }) {
    return SpeechProfileRecord(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      displayName: displayName == null ? this.displayName : displayName(),
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      learningPaused: learningPaused ?? this.learningPaused,
      embeddingCount: embeddingCount ?? this.embeddingCount,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(id);
    serializer.serializeString(kind);
    TraitHelpers.serializeOptionStr(displayName, serializer);
    serializer.serializeInt64(createdAtMs);
    serializer.serializeInt64(updatedAtMs);
    serializer.serializeBool(learningPaused);
    serializer.serializeInt64(embeddingCount);
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

    return other is SpeechProfileRecord &&
        id == other.id &&
        kind == other.kind &&
        displayName == other.displayName &&
        createdAtMs == other.createdAtMs &&
        updatedAtMs == other.updatedAtMs &&
        learningPaused == other.learningPaused &&
        embeddingCount == other.embeddingCount;
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    displayName,
    createdAtMs,
    updatedAtMs,
    learningPaused,
    embeddingCount,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'id: $id, '
          'kind: $kind, '
          'displayName: [REDACTED], '
          'createdAtMs: $createdAtMs, '
          'updatedAtMs: $updatedAtMs, '
          'learningPaused: $learningPaused, '
          'embeddingCount: $embeddingCount'
          ')';
      return true;
    }());

    return fullString ?? 'SpeechProfileRecord';
  }
}
