// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class LiveVoiceAudio {
  const LiveVoiceAudio({
    required this.liveStreamId,
    required this.sequence,
    required this.sampleRateHz,
    required this.bytes,
  });

  static LiveVoiceAudio deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = LiveVoiceAudio(
      liveStreamId: deserializer.deserializeString(),
      sequence: deserializer.deserializeUint64(),
      sampleRateHz: deserializer.deserializeUint32(),
      bytes: TraitHelpers.deserializeVectorU8(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static LiveVoiceAudio bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = LiveVoiceAudio.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String liveStreamId;
  final Uint64 sequence;
  final int sampleRateHz;
  final List<int> bytes;

  LiveVoiceAudio copyWith({
    String? liveStreamId,
    Uint64? sequence,
    int? sampleRateHz,
    List<int>? bytes,
  }) {
    return LiveVoiceAudio(
      liveStreamId: liveStreamId ?? this.liveStreamId,
      sequence: sequence ?? this.sequence,
      sampleRateHz: sampleRateHz ?? this.sampleRateHz,
      bytes: bytes ?? this.bytes,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(liveStreamId);
    serializer.serializeUint64(sequence);
    serializer.serializeUint32(sampleRateHz);
    TraitHelpers.serializeVectorU8(bytes, serializer);
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

    return other is LiveVoiceAudio &&
        liveStreamId == other.liveStreamId &&
        sequence == other.sequence &&
        sampleRateHz == other.sampleRateHz &&
        listEquals(bytes, other.bytes);
  }

  @override
  int get hashCode => Object.hash(liveStreamId, sequence, sampleRateHz, bytes);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'liveStreamId: $liveStreamId, '
          'sequence: $sequence, '
          'sampleRateHz: $sampleRateHz, '
          'bytes: $bytes'
          ')';
      return true;
    }());

    return fullString ?? 'LiveVoiceAudio';
  }
}
