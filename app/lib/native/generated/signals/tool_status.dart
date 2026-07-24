// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum ToolStatus {
  queued,
  running,
  waitingForApproval,
  complete,
  failed,
  cancelled,
}

extension ToolStatusExtension on ToolStatus {
  static ToolStatus deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return ToolStatus.queued;
      case 1:
        return ToolStatus.running;
      case 2:
        return ToolStatus.waitingForApproval;
      case 3:
        return ToolStatus.complete;
      case 4:
        return ToolStatus.failed;
      case 5:
        return ToolStatus.cancelled;
      default:
        throw Exception(
          'Unknown variant index for ToolStatus: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case ToolStatus.queued:
        return serializer.serializeVariantIndex(0);
      case ToolStatus.running:
        return serializer.serializeVariantIndex(1);
      case ToolStatus.waitingForApproval:
        return serializer.serializeVariantIndex(2);
      case ToolStatus.complete:
        return serializer.serializeVariantIndex(3);
      case ToolStatus.failed:
        return serializer.serializeVariantIndex(4);
      case ToolStatus.cancelled:
        return serializer.serializeVariantIndex(5);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static ToolStatus bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ToolStatusExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
