// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Why a frame was not taken. Carried into the UI so a user who wonders "is it
/// recording right now?" gets a truthful answer instead of a spinner.
enum RewindSkipReason {
  deniedApp,
  privateWindow,
  screenLocked,
  paused,
  idle,
  heartbeat,
  minimumInterval,
  busy,
  unchanged,
  noPermission,
}

extension RewindSkipReasonExtension on RewindSkipReason {
  static RewindSkipReason deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return RewindSkipReason.deniedApp;
      case 1:
        return RewindSkipReason.privateWindow;
      case 2:
        return RewindSkipReason.screenLocked;
      case 3:
        return RewindSkipReason.paused;
      case 4:
        return RewindSkipReason.idle;
      case 5:
        return RewindSkipReason.heartbeat;
      case 6:
        return RewindSkipReason.minimumInterval;
      case 7:
        return RewindSkipReason.busy;
      case 8:
        return RewindSkipReason.unchanged;
      case 9:
        return RewindSkipReason.noPermission;
      default:
        throw Exception(
          'Unknown variant index for RewindSkipReason: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case RewindSkipReason.deniedApp:
        return serializer.serializeVariantIndex(0);
      case RewindSkipReason.privateWindow:
        return serializer.serializeVariantIndex(1);
      case RewindSkipReason.screenLocked:
        return serializer.serializeVariantIndex(2);
      case RewindSkipReason.paused:
        return serializer.serializeVariantIndex(3);
      case RewindSkipReason.idle:
        return serializer.serializeVariantIndex(4);
      case RewindSkipReason.heartbeat:
        return serializer.serializeVariantIndex(5);
      case RewindSkipReason.minimumInterval:
        return serializer.serializeVariantIndex(6);
      case RewindSkipReason.busy:
        return serializer.serializeVariantIndex(7);
      case RewindSkipReason.unchanged:
        return serializer.serializeVariantIndex(8);
      case RewindSkipReason.noPermission:
        return serializer.serializeVariantIndex(9);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static RewindSkipReason bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RewindSkipReasonExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
