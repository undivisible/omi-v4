// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class LiveVoiceTranscript {
  const LiveVoiceTranscript({
    required this.liveStreamId,
    required this.text,
    required this.finalSegment,
  });

  static LiveVoiceTranscript deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = LiveVoiceTranscript(
      liveStreamId: deserializer.deserializeString(),
      text: deserializer.deserializeString(),
      finalSegment: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static LiveVoiceTranscript bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = LiveVoiceTranscript.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String liveStreamId;
  final String text;
  final bool finalSegment;

  LiveVoiceTranscript copyWith({
    String? liveStreamId,
    String? text,
    bool? finalSegment,
  }) {
    return LiveVoiceTranscript(
      liveStreamId: liveStreamId ?? this.liveStreamId,
      text: text ?? this.text,
      finalSegment: finalSegment ?? this.finalSegment,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(liveStreamId);
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

    return other is LiveVoiceTranscript &&
        liveStreamId == other.liveStreamId &&
        text == other.text &&
        finalSegment == other.finalSegment;
  }

  @override
  int get hashCode => Object.hash(liveStreamId, text, finalSegment);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'liveStreamId: $liveStreamId, '
          'text: [REDACTED], '
          'finalSegment: $finalSegment'
          ')';
      return true;
    }());

    return fullString ?? 'LiveVoiceTranscript';
  }
}
