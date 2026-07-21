// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class TranscriptionStopAcknowledgement {
  const TranscriptionStopAcknowledgement({
    required this.requestId,
    required this.audioStreamId,
    required this.accepted,
  });

  static TranscriptionStopAcknowledgement deserialize(
    BinaryDeserializer deserializer,
  ) {
    deserializer.increaseContainerDepth();
    final instance = TranscriptionStopAcknowledgement(
      requestId: deserializer.deserializeString(),
      audioStreamId: deserializer.deserializeString(),
      accepted: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static TranscriptionStopAcknowledgement bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TranscriptionStopAcknowledgement.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String audioStreamId;
  final bool accepted;

  TranscriptionStopAcknowledgement copyWith({
    String? requestId,
    String? audioStreamId,
    bool? accepted,
  }) {
    return TranscriptionStopAcknowledgement(
      requestId: requestId ?? this.requestId,
      audioStreamId: audioStreamId ?? this.audioStreamId,
      accepted: accepted ?? this.accepted,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeString(audioStreamId);
    serializer.serializeBool(accepted);
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

    return other is TranscriptionStopAcknowledgement &&
        requestId == other.requestId &&
        audioStreamId == other.audioStreamId &&
        accepted == other.accepted;
  }

  @override
  int get hashCode => Object.hash(requestId, audioStreamId, accepted);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'audioStreamId: $audioStreamId, '
          'accepted: $accepted'
          ')';
      return true;
    }());

    return fullString ?? 'TranscriptionStopAcknowledgement';
  }
}
