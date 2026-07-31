// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The answer to exactly one speech-profile command.
@immutable
class SpeechProfileUpdate {
  const SpeechProfileUpdate({required this.requestId, required this.payload});

  static SpeechProfileUpdate deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = SpeechProfileUpdate(
      requestId: deserializer.deserializeString(),
      payload: SpeechProfilePayload.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static SpeechProfileUpdate bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SpeechProfileUpdate.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final SpeechProfilePayload payload;

  SpeechProfileUpdate copyWith({
    String? requestId,
    SpeechProfilePayload? payload,
  }) {
    return SpeechProfileUpdate(
      requestId: requestId ?? this.requestId,
      payload: payload ?? this.payload,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    payload.serialize(serializer);
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

    return other is SpeechProfileUpdate &&
        requestId == other.requestId &&
        payload == other.payload;
  }

  @override
  int get hashCode => Object.hash(requestId, payload);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'payload: $payload'
          ')';
      return true;
    }());

    return fullString ?? 'SpeechProfileUpdate';
  }
}
