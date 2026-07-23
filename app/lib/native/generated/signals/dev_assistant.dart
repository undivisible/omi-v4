// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The answer to a [`Command::ResolveDevAssistant`]. `credential` is the
/// developer Gemini key when one was found — the client needs the value
/// itself to open a Gemini Live session — and `None` otherwise, in which case
/// `missing_key_hint` names every place a key may be put.
@immutable
class DevAssistant {
  const DevAssistant({
    required this.requestId,
    this.credential,
    required this.liveModel,
    required this.missingKeyHint,
  });

  static DevAssistant deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = DevAssistant(
      requestId: deserializer.deserializeString(),
      credential: TraitHelpers.deserializeOptionStr(deserializer),
      liveModel: deserializer.deserializeString(),
      missingKeyHint: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static DevAssistant bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = DevAssistant.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String? credential;
  final String liveModel;
  final String missingKeyHint;

  DevAssistant copyWith({
    String? requestId,
    String? Function()? credential,
    String? liveModel,
    String? missingKeyHint,
  }) {
    return DevAssistant(
      requestId: requestId ?? this.requestId,
      credential: credential == null ? this.credential : credential(),
      liveModel: liveModel ?? this.liveModel,
      missingKeyHint: missingKeyHint ?? this.missingKeyHint,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    TraitHelpers.serializeOptionStr(credential, serializer);
    serializer.serializeString(liveModel);
    serializer.serializeString(missingKeyHint);
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

    return other is DevAssistant &&
        requestId == other.requestId &&
        credential == other.credential &&
        liveModel == other.liveModel &&
        missingKeyHint == other.missingKeyHint;
  }

  @override
  int get hashCode =>
      Object.hash(requestId, credential, liveModel, missingKeyHint);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'credential: $credential, '
          'liveModel: $liveModel, '
          'missingKeyHint: $missingKeyHint'
          ')';
      return true;
    }());

    return fullString ?? 'DevAssistant';
  }
}
