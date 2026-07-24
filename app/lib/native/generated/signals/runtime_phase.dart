// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum RuntimePhase { starting, ready, busy, degraded, stopping }

extension RuntimePhaseExtension on RuntimePhase {
  static RuntimePhase deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return RuntimePhase.starting;
      case 1:
        return RuntimePhase.ready;
      case 2:
        return RuntimePhase.busy;
      case 3:
        return RuntimePhase.degraded;
      case 4:
        return RuntimePhase.stopping;
      default:
        throw Exception(
          'Unknown variant index for RuntimePhase: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case RuntimePhase.starting:
        return serializer.serializeVariantIndex(0);
      case RuntimePhase.ready:
        return serializer.serializeVariantIndex(1);
      case RuntimePhase.busy:
        return serializer.serializeVariantIndex(2);
      case RuntimePhase.degraded:
        return serializer.serializeVariantIndex(3);
      case RuntimePhase.stopping:
        return serializer.serializeVariantIndex(4);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static RuntimePhase bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RuntimePhaseExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
