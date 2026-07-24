// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class ComputerUsePermission {
  const ComputerUsePermission({required this.name, required this.granted});

  static ComputerUsePermission deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComputerUsePermission(
      name: deserializer.deserializeString(),
      granted: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ComputerUsePermission bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ComputerUsePermission.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String name;
  final bool granted;

  ComputerUsePermission copyWith({String? name, bool? granted}) {
    return ComputerUsePermission(
      name: name ?? this.name,
      granted: granted ?? this.granted,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(name);
    serializer.serializeBool(granted);
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

    return other is ComputerUsePermission &&
        name == other.name &&
        granted == other.granted;
  }

  @override
  int get hashCode => Object.hash(name, granted);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'name: $name, '
          'granted: $granted'
          ')';
      return true;
    }());

    return fullString ?? 'ComputerUsePermission';
  }
}
