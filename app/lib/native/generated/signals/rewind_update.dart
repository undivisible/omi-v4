// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The answer to exactly one [`RewindRequest`].
@immutable
class RewindUpdate {
  const RewindUpdate({required this.requestId, required this.payload});

  static RewindUpdate deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindUpdate(
      requestId: deserializer.deserializeString(),
      payload: RewindPayload.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RewindUpdate bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RewindUpdate.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final RewindPayload payload;

  RewindUpdate copyWith({String? requestId, RewindPayload? payload}) {
    return RewindUpdate(
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

    return other is RewindUpdate &&
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

    return fullString ?? 'RewindUpdate';
  }
}
