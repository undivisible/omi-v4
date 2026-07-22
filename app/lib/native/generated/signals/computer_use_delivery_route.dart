// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum ComputerUseDeliveryRoute { targetAddressed, pointer, unknown }

extension ComputerUseDeliveryRouteExtension on ComputerUseDeliveryRoute {
  static ComputerUseDeliveryRoute deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return ComputerUseDeliveryRoute.targetAddressed;
      case 1:
        return ComputerUseDeliveryRoute.pointer;
      case 2:
        return ComputerUseDeliveryRoute.unknown;
      default:
        throw Exception(
          'Unknown variant index for ComputerUseDeliveryRoute: ' +
              index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case ComputerUseDeliveryRoute.targetAddressed:
        return serializer.serializeVariantIndex(0);
      case ComputerUseDeliveryRoute.pointer:
        return serializer.serializeVariantIndex(1);
      case ComputerUseDeliveryRoute.unknown:
        return serializer.serializeVariantIndex(2);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static ComputerUseDeliveryRoute bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ComputerUseDeliveryRouteExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
