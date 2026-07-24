// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum TranscriptionRoute { managed, byok, local }

extension TranscriptionRouteExtension on TranscriptionRoute {
  static TranscriptionRoute deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return TranscriptionRoute.managed;
      case 1:
        return TranscriptionRoute.byok;
      case 2:
        return TranscriptionRoute.local;
      default:
        throw Exception(
          'Unknown variant index for TranscriptionRoute: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case TranscriptionRoute.managed:
        return serializer.serializeVariantIndex(0);
      case TranscriptionRoute.byok:
        return serializer.serializeVariantIndex(1);
      case TranscriptionRoute.local:
        return serializer.serializeVariantIndex(2);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static TranscriptionRoute bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TranscriptionRouteExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
