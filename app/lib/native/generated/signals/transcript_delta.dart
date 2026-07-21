// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class TranscriptDelta {
  const TranscriptDelta({
    required this.requestId,
    required this.segmentSequence,
    required this.occurredAtMs,
    required this.text,
    required this.finalSegment,
    this.language,
  });

  static TranscriptDelta deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TranscriptDelta(
      requestId: deserializer.deserializeString(),
      segmentSequence: deserializer.deserializeUint64(),
      occurredAtMs: deserializer.deserializeInt64(),
      text: deserializer.deserializeString(),
      finalSegment: deserializer.deserializeBool(),
      language: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static TranscriptDelta bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TranscriptDelta.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final Uint64 segmentSequence;
  final int occurredAtMs;
  final String text;
  final bool finalSegment;
  final String? language;

  TranscriptDelta copyWith({
    String? requestId,
    Uint64? segmentSequence,
    int? occurredAtMs,
    String? text,
    bool? finalSegment,
    String? Function()? language,
  }) {
    return TranscriptDelta(
      requestId: requestId ?? this.requestId,
      segmentSequence: segmentSequence ?? this.segmentSequence,
      occurredAtMs: occurredAtMs ?? this.occurredAtMs,
      text: text ?? this.text,
      finalSegment: finalSegment ?? this.finalSegment,
      language: language == null ? this.language : language(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeUint64(segmentSequence);
    serializer.serializeInt64(occurredAtMs);
    serializer.serializeString(text);
    serializer.serializeBool(finalSegment);
    TraitHelpers.serializeOptionStr(language, serializer);
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

    return other is TranscriptDelta &&
        requestId == other.requestId &&
        segmentSequence == other.segmentSequence &&
        occurredAtMs == other.occurredAtMs &&
        text == other.text &&
        finalSegment == other.finalSegment &&
        language == other.language;
  }

  @override
  int get hashCode => Object.hash(
    requestId,
    segmentSequence,
    occurredAtMs,
    text,
    finalSegment,
    language,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'segmentSequence: $segmentSequence, '
          'occurredAtMs: $occurredAtMs, '
          'text: $text, '
          'finalSegment: $finalSegment, '
          'language: $language'
          ')';
      return true;
    }());

    return fullString ?? 'TranscriptDelta';
  }
}
