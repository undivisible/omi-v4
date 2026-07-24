// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Where a [`Command::JoinCall`] has got to. Exactly one terminal phase
/// (`Ended` or `Failed`) is sent per call.
@immutable
class CallState {
  const CallState({required this.requestId, required this.state, this.detail});

  static CallState deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CallState(
      requestId: deserializer.deserializeString(),
      state: CallPhaseExtension.deserialize(deserializer),
      detail: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static CallState bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CallState.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final CallPhase state;
  final String? detail;

  CallState copyWith({
    String? requestId,
    CallPhase? state,
    String? Function()? detail,
  }) {
    return CallState(
      requestId: requestId ?? this.requestId,
      state: state ?? this.state,
      detail: detail == null ? this.detail : detail(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
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

    return other is CallState &&
        requestId == other.requestId &&
        state == other.state &&
        detail == other.detail;
  }

  @override
  int get hashCode => Object.hash(requestId, state, detail);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'state: $state, '
          'detail: $detail'
          ')';
      return true;
    }());

    return fullString ?? 'CallState';
  }
}
