// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum CaptureSource { screen, clipboard, accessibility, omiDevice, chat }

extension CaptureSourceExtension on CaptureSource {
  static CaptureSource deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return CaptureSource.screen;
      case 1:
        return CaptureSource.clipboard;
      case 2:
        return CaptureSource.accessibility;
      case 3:
        return CaptureSource.omiDevice;
      case 4:
        return CaptureSource.chat;
      default:
        throw Exception(
          'Unknown variant index for CaptureSource: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case CaptureSource.screen:
        return serializer.serializeVariantIndex(0);
      case CaptureSource.clipboard:
        return serializer.serializeVariantIndex(1);
      case CaptureSource.accessibility:
        return serializer.serializeVariantIndex(2);
      case CaptureSource.omiDevice:
        return serializer.serializeVariantIndex(3);
      case CaptureSource.chat:
        return serializer.serializeVariantIndex(4);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static CaptureSource bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CaptureSourceExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
