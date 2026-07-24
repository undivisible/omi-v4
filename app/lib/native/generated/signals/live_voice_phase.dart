// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum LiveVoicePhase { started, interrupted, ended, failed }

extension LiveVoicePhaseExtension on LiveVoicePhase {
  static LiveVoicePhase deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return LiveVoicePhase.started;
      case 1:
        return LiveVoicePhase.interrupted;
      case 2:
        return LiveVoicePhase.ended;
      case 3:
        return LiveVoicePhase.failed;
      default:
        throw Exception(
          'Unknown variant index for LiveVoicePhase: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case LiveVoicePhase.started:
        return serializer.serializeVariantIndex(0);
      case LiveVoicePhase.interrupted:
        return serializer.serializeVariantIndex(1);
      case LiveVoicePhase.ended:
        return serializer.serializeVariantIndex(2);
      case LiveVoicePhase.failed:
        return serializer.serializeVariantIndex(3);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static LiveVoicePhase bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = LiveVoicePhaseExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
