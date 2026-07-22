// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum ComputerUseBackgroundSupport {
  guarded,
  hostIsolatedOnly,
  unavailable,
  unknown,
}

extension ComputerUseBackgroundSupportExtension
    on ComputerUseBackgroundSupport {
  static ComputerUseBackgroundSupport deserialize(
    BinaryDeserializer deserializer,
  ) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return ComputerUseBackgroundSupport.guarded;
      case 1:
        return ComputerUseBackgroundSupport.hostIsolatedOnly;
      case 2:
        return ComputerUseBackgroundSupport.unavailable;
      case 3:
        return ComputerUseBackgroundSupport.unknown;
      default:
        throw Exception(
          'Unknown variant index for ComputerUseBackgroundSupport: ' +
              index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case ComputerUseBackgroundSupport.guarded:
        return serializer.serializeVariantIndex(0);
      case ComputerUseBackgroundSupport.hostIsolatedOnly:
        return serializer.serializeVariantIndex(1);
      case ComputerUseBackgroundSupport.unavailable:
        return serializer.serializeVariantIndex(2);
      case ComputerUseBackgroundSupport.unknown:
        return serializer.serializeVariantIndex(3);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static ComputerUseBackgroundSupport bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ComputerUseBackgroundSupportExtension.deserialize(
      deserializer,
    );
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
