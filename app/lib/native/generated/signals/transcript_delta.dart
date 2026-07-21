// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class TranscriptDelta {
  const TranscriptDelta({
    required this.requestId,
    required this.text,
    required this.finalSegment,
    this.language,
  });

  static TranscriptDelta deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TranscriptDelta(
      requestId: deserializer.deserializeString(),
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
  final String text;
  final bool finalSegment;
  final String? language;

  TranscriptDelta copyWith({
    String? requestId,
    String? text,
    bool? finalSegment,
    String? Function()? language,
  }) {
    return TranscriptDelta(
      requestId: requestId ?? this.requestId,
      text: text ?? this.text,
      finalSegment: finalSegment ?? this.finalSegment,
      language: language == null ? this.language : language(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
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
        text == other.text &&
        finalSegment == other.finalSegment &&
        language == other.language;
  }

  @override
  int get hashCode => Object.hash(requestId, text, finalSegment, language);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'text: $text, '
          'finalSegment: $finalSegment, '
          'language: $language'
          ')';
      return true;
    }());

    return fullString ?? 'TranscriptDelta';
  }
}
