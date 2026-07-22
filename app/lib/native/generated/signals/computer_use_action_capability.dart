// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class ComputerUseActionCapability {
  const ComputerUseActionCapability({
    required this.name,
    required this.available,
    required this.deliveryRoute,
    required this.backgroundSupport,
  });

  static ComputerUseActionCapability deserialize(
    BinaryDeserializer deserializer,
  ) {
    deserializer.increaseContainerDepth();
    final instance = ComputerUseActionCapability(
      name: deserializer.deserializeString(),
      available: deserializer.deserializeBool(),
      deliveryRoute: ComputerUseDeliveryRouteExtension.deserialize(
        deserializer,
      ),
      backgroundSupport: ComputerUseBackgroundSupportExtension.deserialize(
        deserializer,
      ),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ComputerUseActionCapability bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ComputerUseActionCapability.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String name;
  final bool available;
  final ComputerUseDeliveryRoute deliveryRoute;
  final ComputerUseBackgroundSupport backgroundSupport;

  ComputerUseActionCapability copyWith({
    String? name,
    bool? available,
    ComputerUseDeliveryRoute? deliveryRoute,
    ComputerUseBackgroundSupport? backgroundSupport,
  }) {
    return ComputerUseActionCapability(
      name: name ?? this.name,
      available: available ?? this.available,
      deliveryRoute: deliveryRoute ?? this.deliveryRoute,
      backgroundSupport: backgroundSupport ?? this.backgroundSupport,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(name);
    serializer.serializeBool(available);
    deliveryRoute.serialize(serializer);
    backgroundSupport.serialize(serializer);
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

    return other is ComputerUseActionCapability &&
        name == other.name &&
        available == other.available &&
        deliveryRoute == other.deliveryRoute &&
        backgroundSupport == other.backgroundSupport;
  }

  @override
  int get hashCode =>
      Object.hash(name, available, deliveryRoute, backgroundSupport);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'name: $name, '
          'available: $available, '
          'deliveryRoute: $deliveryRoute, '
          'backgroundSupport: $backgroundSupport'
          ')';
      return true;
    }());

    return fullString ?? 'ComputerUseActionCapability';
  }
}
