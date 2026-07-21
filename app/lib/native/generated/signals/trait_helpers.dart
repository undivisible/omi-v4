// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

class TraitHelpers {
  static void serializeOptionI64(int? value, BinarySerializer serializer) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      serializer.serializeInt64(value);
    }
  }

  static int? deserializeOptionI64(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return deserializer.deserializeInt64();
    } else {
      return null;
    }
  }

  static void serializeOptionStr(String? value, BinarySerializer serializer) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      serializer.serializeString(value);
    }
  }

  static String? deserializeOptionStr(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return deserializer.deserializeString();
    } else {
      return null;
    }
  }

  static void serializeOptionU8(int? value, BinarySerializer serializer) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      serializer.serializeUint8(value);
    }
  }

  static int? deserializeOptionU8(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return deserializer.deserializeUint8();
    } else {
      return null;
    }
  }

  static void serializeVectorMemorySearchItem(
    List<MemorySearchItem> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      item.serialize(serializer);
    }
  }

  static List<MemorySearchItem> deserializeVectorMemorySearchItem(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(
      length,
      (_) => MemorySearchItem.deserialize(deserializer),
    );
  }

  static void serializeVectorStr(
    List<String> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      serializer.serializeString(item);
    }
  }

  static List<String> deserializeVectorStr(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => deserializer.deserializeString());
  }
}
