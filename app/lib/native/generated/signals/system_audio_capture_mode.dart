// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum SystemAudioCaptureMode { always, onlyDuringMeetings, never }

extension SystemAudioCaptureModeExtension on SystemAudioCaptureMode {
  static SystemAudioCaptureMode deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return SystemAudioCaptureMode.always;
      case 1:
        return SystemAudioCaptureMode.onlyDuringMeetings;
      case 2:
        return SystemAudioCaptureMode.never;
      default:
        throw Exception(
          'Unknown variant index for SystemAudioCaptureMode: ' +
              index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case SystemAudioCaptureMode.always:
        return serializer.serializeVariantIndex(0);
      case SystemAudioCaptureMode.onlyDuringMeetings:
        return serializer.serializeVariantIndex(1);
      case SystemAudioCaptureMode.never:
        return serializer.serializeVariantIndex(2);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static SystemAudioCaptureMode bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SystemAudioCaptureModeExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
