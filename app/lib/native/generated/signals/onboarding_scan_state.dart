// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum OnboardingScanState { complete, denied, unavailable, failed }

extension OnboardingScanStateExtension on OnboardingScanState {
  static OnboardingScanState deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return OnboardingScanState.complete;
      case 1:
        return OnboardingScanState.denied;
      case 2:
        return OnboardingScanState.unavailable;
      case 3:
        return OnboardingScanState.failed;
      default:
        throw Exception(
          'Unknown variant index for OnboardingScanState: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case OnboardingScanState.complete:
        return serializer.serializeVariantIndex(0);
      case OnboardingScanState.denied:
        return serializer.serializeVariantIndex(1);
      case OnboardingScanState.unavailable:
        return serializer.serializeVariantIndex(2);
      case OnboardingScanState.failed:
        return serializer.serializeVariantIndex(3);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static OnboardingScanState bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = OnboardingScanStateExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
