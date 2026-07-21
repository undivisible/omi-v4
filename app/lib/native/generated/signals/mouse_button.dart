// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum MouseButton { left, right, middle }

extension MouseButtonExtension on MouseButton {
  static MouseButton deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return MouseButton.left;
      case 1:
        return MouseButton.right;
      case 2:
        return MouseButton.middle;
      default:
        throw Exception(
          'Unknown variant index for MouseButton: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case MouseButton.left:
        return serializer.serializeVariantIndex(0);
      case MouseButton.right:
        return serializer.serializeVariantIndex(1);
      case MouseButton.middle:
        return serializer.serializeVariantIndex(2);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static MouseButton bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MouseButtonExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
