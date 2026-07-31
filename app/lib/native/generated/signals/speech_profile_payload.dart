// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

abstract class SpeechProfilePayload {
  const SpeechProfilePayload();

  void serialize(BinarySerializer serializer);

  static SpeechProfilePayload deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return SpeechProfilePayloadProfiles.load(deserializer);
      case 1:
        return SpeechProfilePayloadUnavailable.load(deserializer);
      default:
        throw Exception(
          'Unknown variant index for SpeechProfilePayload: ' + index.toString(),
        );
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static SpeechProfilePayload bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SpeechProfilePayload.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

@immutable
class SpeechProfilePayloadProfiles extends SpeechProfilePayload {
  const SpeechProfilePayloadProfiles({required this.profiles}) : super();

  static SpeechProfilePayloadProfiles load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = SpeechProfilePayloadProfiles(
      profiles: TraitHelpers.deserializeVectorSpeechProfileRecord(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<SpeechProfileRecord> profiles;

  SpeechProfilePayloadProfiles copyWith({List<SpeechProfileRecord>? profiles}) {
    return SpeechProfilePayloadProfiles(profiles: profiles ?? this.profiles);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    TraitHelpers.serializeVectorSpeechProfileRecord(profiles, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is SpeechProfilePayloadProfiles &&
        listEquals(profiles, other.profiles);
  }

  @override
  int get hashCode => profiles.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'profiles: $profiles'
          ')';
      return true;
    }());

    return fullString ?? 'SpeechProfilePayloadProfiles';
  }
}

@immutable
class SpeechProfilePayloadUnavailable extends SpeechProfilePayload {
  const SpeechProfilePayloadUnavailable({required this.detail}) : super();

  static SpeechProfilePayloadUnavailable load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = SpeechProfilePayloadUnavailable(
      detail: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String detail;

  SpeechProfilePayloadUnavailable copyWith({String? detail}) {
    return SpeechProfilePayloadUnavailable(detail: detail ?? this.detail);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(detail);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is SpeechProfilePayloadUnavailable && detail == other.detail;
  }

  @override
  int get hashCode => detail.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'detail: $detail'
          ')';
      return true;
    }());

    return fullString ?? 'SpeechProfilePayloadUnavailable';
  }
}
