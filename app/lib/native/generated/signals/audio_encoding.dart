// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum AudioEncoding { pcmS16Le, pcmU8, opus }

extension AudioEncodingExtension on AudioEncoding {
  static AudioEncoding deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return AudioEncoding.pcmS16Le;
      case 1:
        return AudioEncoding.pcmU8;
      case 2:
        return AudioEncoding.opus;
      default:
        throw Exception(
          'Unknown variant index for AudioEncoding: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case AudioEncoding.pcmS16Le:
        return serializer.serializeVariantIndex(0);
      case AudioEncoding.pcmU8:
        return serializer.serializeVariantIndex(1);
      case AudioEncoding.opus:
        return serializer.serializeVariantIndex(2);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static AudioEncoding bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = AudioEncodingExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
