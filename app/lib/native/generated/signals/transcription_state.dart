// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum TranscriptionState {
  started,
  reconnecting,
  draining,
  finished,
  cancelled,
  failed,
}

extension TranscriptionStateExtension on TranscriptionState {
  static TranscriptionState deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return TranscriptionState.started;
      case 1:
        return TranscriptionState.reconnecting;
      case 2:
        return TranscriptionState.draining;
      case 3:
        return TranscriptionState.finished;
      case 4:
        return TranscriptionState.cancelled;
      case 5:
        return TranscriptionState.failed;
      default:
        throw Exception(
          'Unknown variant index for TranscriptionState: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case TranscriptionState.started:
        return serializer.serializeVariantIndex(0);
      case TranscriptionState.reconnecting:
        return serializer.serializeVariantIndex(1);
      case TranscriptionState.draining:
        return serializer.serializeVariantIndex(2);
      case TranscriptionState.finished:
        return serializer.serializeVariantIndex(3);
      case TranscriptionState.cancelled:
        return serializer.serializeVariantIndex(4);
      case TranscriptionState.failed:
        return serializer.serializeVariantIndex(5);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static TranscriptionState bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TranscriptionStateExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
