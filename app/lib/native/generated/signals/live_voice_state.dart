// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class LiveVoiceState {
  const LiveVoiceState({
    required this.liveStreamId,
    required this.state,
    this.detail,
  });

  static LiveVoiceState deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = LiveVoiceState(
      liveStreamId: deserializer.deserializeString(),
      state: LiveVoicePhaseExtension.deserialize(deserializer),
      detail: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static LiveVoiceState bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = LiveVoiceState.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String liveStreamId;
  final LiveVoicePhase state;
  final String? detail;

  LiveVoiceState copyWith({
    String? liveStreamId,
    LiveVoicePhase? state,
    String? Function()? detail,
  }) {
    return LiveVoiceState(
      liveStreamId: liveStreamId ?? this.liveStreamId,
      state: state ?? this.state,
      detail: detail == null ? this.detail : detail(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(liveStreamId);
    state.serialize(serializer);
    TraitHelpers.serializeOptionStr(detail, serializer);
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

    return other is LiveVoiceState &&
        liveStreamId == other.liveStreamId &&
        state == other.state &&
        detail == other.detail;
  }

  @override
  int get hashCode => Object.hash(liveStreamId, state, detail);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'liveStreamId: $liveStreamId, '
          'state: $state, '
          'detail: $detail'
          ')';
      return true;
    }());

    return fullString ?? 'LiveVoiceState';
  }
}
