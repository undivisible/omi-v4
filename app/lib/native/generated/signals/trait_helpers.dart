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

  static void serializeOptionComputerUseAuthorityReceipt(
    ComputerUseAuthorityReceipt? value,
    BinarySerializer serializer,
  ) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      value.serialize(serializer);
    }
  }

  static ComputerUseAuthorityReceipt?
  deserializeOptionComputerUseAuthorityReceipt(
    BinaryDeserializer deserializer,
  ) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return ComputerUseAuthorityReceipt.deserialize(deserializer);
    } else {
      return null;
    }
  }

  static void serializeOptionComputerUseCapabilities(
    ComputerUseCapabilities? value,
    BinarySerializer serializer,
  ) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      value.serialize(serializer);
    }
  }

  static ComputerUseCapabilities? deserializeOptionComputerUseCapabilities(
    BinaryDeserializer deserializer,
  ) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return ComputerUseCapabilities.deserialize(deserializer);
    } else {
      return null;
    }
  }

  static void serializeOptionComputerUseTargetProvenance(
    ComputerUseTargetProvenance? value,
    BinarySerializer serializer,
  ) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      value.serialize(serializer);
    }
  }

  static ComputerUseTargetProvenance?
  deserializeOptionComputerUseTargetProvenance(
    BinaryDeserializer deserializer,
  ) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return ComputerUseTargetProvenance.deserialize(deserializer);
    } else {
      return null;
    }
  }

  static void serializeOptionMessageOrigin(
    MessageOrigin? value,
    BinarySerializer serializer,
  ) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      value.serialize(serializer);
    }
  }

  static MessageOrigin? deserializeOptionMessageOrigin(
    BinaryDeserializer deserializer,
  ) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return MessageOriginExtension.deserialize(deserializer);
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

  static void serializeVectorComputerUseActionCapability(
    List<ComputerUseActionCapability> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      item.serialize(serializer);
    }
  }

  static List<ComputerUseActionCapability>
  deserializeVectorComputerUseActionCapability(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(
      length,
      (_) => ComputerUseActionCapability.deserialize(deserializer),
    );
  }

  static void serializeVectorComputerUsePermission(
    List<ComputerUsePermission> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      item.serialize(serializer);
    }
  }

  static List<ComputerUsePermission> deserializeVectorComputerUsePermission(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(
      length,
      (_) => ComputerUsePermission.deserialize(deserializer),
    );
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

  static void serializeVectorU8(List<int> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      serializer.serializeUint8(item);
    }
  }

  static List<int> deserializeVectorU8(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => deserializer.deserializeUint8());
  }
}
