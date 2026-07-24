// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class TranscriptionStatus {
  const TranscriptionStatus({
    required this.requestId,
    required this.audioStreamId,
    required this.state,
    required this.sttEpoch,
  });

  static TranscriptionStatus deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TranscriptionStatus(
      requestId: deserializer.deserializeString(),
      audioStreamId: deserializer.deserializeString(),
      state: TranscriptionStateExtension.deserialize(deserializer),
      sttEpoch: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static TranscriptionStatus bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TranscriptionStatus.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String audioStreamId;
  final TranscriptionState state;
  final int sttEpoch;

  TranscriptionStatus copyWith({
    String? requestId,
    String? audioStreamId,
    TranscriptionState? state,
    int? sttEpoch,
  }) {
    return TranscriptionStatus(
      requestId: requestId ?? this.requestId,
      audioStreamId: audioStreamId ?? this.audioStreamId,
      state: state ?? this.state,
      sttEpoch: sttEpoch ?? this.sttEpoch,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeString(audioStreamId);
    state.serialize(serializer);
    serializer.serializeUint32(sttEpoch);
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

    return other is TranscriptionStatus &&
        requestId == other.requestId &&
        audioStreamId == other.audioStreamId &&
        state == other.state &&
        sttEpoch == other.sttEpoch;
  }

  @override
  int get hashCode => Object.hash(requestId, audioStreamId, state, sttEpoch);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'audioStreamId: $audioStreamId, '
          'state: $state, '
          'sttEpoch: $sttEpoch'
          ')';
      return true;
    }());

    return fullString ?? 'TranscriptionStatus';
  }
}
