// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum CallPhase { joining, joined, ended, failed }

extension CallPhaseExtension on CallPhase {
  static CallPhase deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return CallPhase.joining;
      case 1:
        return CallPhase.joined;
      case 2:
        return CallPhase.ended;
      case 3:
        return CallPhase.failed;
      default:
        throw Exception(
          'Unknown variant index for CallPhase: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case CallPhase.joining:
        return serializer.serializeVariantIndex(0);
      case CallPhase.joined:
        return serializer.serializeVariantIndex(1);
      case CallPhase.ended:
        return serializer.serializeVariantIndex(2);
      case CallPhase.failed:
        return serializer.serializeVariantIndex(3);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static CallPhase bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CallPhaseExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
