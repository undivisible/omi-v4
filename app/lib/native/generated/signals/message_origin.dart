// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


enum MessageOrigin {
  chat,
  overlay,
  channelTelegram,
  channelImessage,
}

extension MessageOriginExtension on MessageOrigin {
  static MessageOrigin deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return MessageOrigin.chat;
      case 1: return MessageOrigin.overlay;
      case 2: return MessageOrigin.channelTelegram;
      case 3: return MessageOrigin.channelImessage;
      default: throw Exception('Unknown variant index for MessageOrigin: ' + index.toString());
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case MessageOrigin.chat: return serializer.serializeVariantIndex(0);
      case MessageOrigin.overlay: return serializer.serializeVariantIndex(1);
      case MessageOrigin.channelTelegram: return serializer.serializeVariantIndex(2);
      case MessageOrigin.channelImessage: return serializer.serializeVariantIndex(3);
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static MessageOrigin bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MessageOriginExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

