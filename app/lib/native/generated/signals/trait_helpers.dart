// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

class TraitHelpers {
  static void serializeOptionComputerUseAction(
    ComputerUseAction? value,
    BinarySerializer serializer,
  ) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      value.serialize(serializer);
    }
  }

  static ComputerUseAction? deserializeOptionComputerUseAction(
    BinaryDeserializer deserializer,
  ) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return ComputerUseAction.deserialize(deserializer);
    } else {
      return null;
    }
  }

  static void serializeOptionTranscriptLocator(
    TranscriptLocator? value,
    BinarySerializer serializer,
  ) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      value.serialize(serializer);
    }
  }

  static TranscriptLocator? deserializeOptionTranscriptLocator(
    BinaryDeserializer deserializer,
  ) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return TranscriptLocator.deserialize(deserializer);
    } else {
      return null;
    }
  }

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

  static void serializeOptionU64(Uint64? value, BinarySerializer serializer) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      serializer.serializeUint64(value);
    }
  }

  static Uint64? deserializeOptionU64(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return deserializer.deserializeUint64();
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

  static void serializeVectorMemoryExportCommit(
    List<MemoryExportCommit> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      item.serialize(serializer);
    }
  }

  static List<MemoryExportCommit> deserializeVectorMemoryExportCommit(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(
      length,
      (_) => MemoryExportCommit.deserialize(deserializer),
    );
  }

  static void serializeVectorMemoryItem(
    List<MemoryItem> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      item.serialize(serializer);
    }
  }

  static List<MemoryItem> deserializeVectorMemoryItem(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => MemoryItem.deserialize(deserializer));
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

  static void serializeVectorOnboardingScanSource(
    List<OnboardingScanSource> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      item.serialize(serializer);
    }
  }

  static List<OnboardingScanSource> deserializeVectorOnboardingScanSource(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(
      length,
      (_) => OnboardingScanSource.deserialize(deserializer),
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
