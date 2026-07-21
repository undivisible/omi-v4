// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class AssistantDelta {
  const AssistantDelta({
    required this.requestId,
    required this.text,
    required this.finalSegment,
  });

  static AssistantDelta deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = AssistantDelta(
      requestId: deserializer.deserializeString(),
      text: deserializer.deserializeString(),
      finalSegment: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static AssistantDelta bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = AssistantDelta.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String text;
  final bool finalSegment;

  AssistantDelta copyWith({
    String? requestId,
    String? text,
    bool? finalSegment,
  }) {
    return AssistantDelta(
      requestId: requestId ?? this.requestId,
      text: text ?? this.text,
      finalSegment: finalSegment ?? this.finalSegment,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeString(text);
    serializer.serializeBool(finalSegment);
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

    return other is AssistantDelta &&
        requestId == other.requestId &&
        text == other.text &&
        finalSegment == other.finalSegment;
  }

  @override
  int get hashCode => Object.hash(requestId, text, finalSegment);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'text: $text, '
          'finalSegment: $finalSegment'
          ')';
      return true;
    }());

    return fullString ?? 'AssistantDelta';
  }
}
