// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MeetingInsight {
  const MeetingInsight({
    required this.kind,
    required this.text,
    required this.sourceText,
    required this.speaker,
  });

  static MeetingInsight deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MeetingInsight(
      kind: deserializer.deserializeString(),
      text: deserializer.deserializeString(),
      sourceText: deserializer.deserializeString(),
      speaker: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MeetingInsight bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MeetingInsight.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String kind;
  final String text;
  final String sourceText;
  final String speaker;

  MeetingInsight copyWith({
    String? kind,
    String? text,
    String? sourceText,
    String? speaker,
  }) {
    return MeetingInsight(
      kind: kind ?? this.kind,
      text: text ?? this.text,
      sourceText: sourceText ?? this.sourceText,
      speaker: speaker ?? this.speaker,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(kind);
    serializer.serializeString(text);
    serializer.serializeString(sourceText);
    serializer.serializeString(speaker);
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

    return other is MeetingInsight &&
        kind == other.kind &&
        text == other.text &&
        sourceText == other.sourceText &&
        speaker == other.speaker;
  }

  @override
  int get hashCode => Object.hash(kind, text, sourceText, speaker);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'kind: $kind, '
          'text: $text, '
          'sourceText: $sourceText, '
          'speaker: $speaker'
          ')';
      return true;
    }());

    return fullString ?? 'MeetingInsight';
  }
}
