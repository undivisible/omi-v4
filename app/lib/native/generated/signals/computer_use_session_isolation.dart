// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum ComputerUseSessionIsolation { sharedDesktop, hostIsolated, unknown }

extension ComputerUseSessionIsolationExtension on ComputerUseSessionIsolation {
  static ComputerUseSessionIsolation deserialize(
    BinaryDeserializer deserializer,
  ) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return ComputerUseSessionIsolation.sharedDesktop;
      case 1:
        return ComputerUseSessionIsolation.hostIsolated;
      case 2:
        return ComputerUseSessionIsolation.unknown;
      default:
        throw Exception(
          'Unknown variant index for ComputerUseSessionIsolation: ' +
              index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case ComputerUseSessionIsolation.sharedDesktop:
        return serializer.serializeVariantIndex(0);
      case ComputerUseSessionIsolation.hostIsolated:
        return serializer.serializeVariantIndex(1);
      case ComputerUseSessionIsolation.unknown:
        return serializer.serializeVariantIndex(2);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static ComputerUseSessionIsolation bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ComputerUseSessionIsolationExtension.deserialize(
      deserializer,
    );
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
