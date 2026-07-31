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

  static void serializeOptionRewindSkipReason(
    RewindSkipReason? value,
    BinarySerializer serializer,
  ) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      value.serialize(serializer);
    }
  }

  static RewindSkipReason? deserializeOptionRewindSkipReason(
    BinaryDeserializer deserializer,
  ) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return RewindSkipReasonExtension.deserialize(deserializer);
    } else {
      return null;
    }
  }

  static void serializeOptionSpeechProfileScope(
    SpeechProfileScope? value,
    BinarySerializer serializer,
  ) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      value.serialize(serializer);
    }
  }

  static SpeechProfileScope? deserializeOptionSpeechProfileScope(
    BinaryDeserializer deserializer,
  ) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return SpeechProfileScope.deserialize(deserializer);
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

  static void serializeOptionBool(bool? value, BinarySerializer serializer) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      serializer.serializeBool(value);
    }
  }

  static bool? deserializeOptionBool(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return deserializer.deserializeBool();
    } else {
      return null;
    }
  }

  static void serializeOptionF32(double? value, BinarySerializer serializer) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      serializer.serializeFloat32(value);
    }
  }

  static double? deserializeOptionF32(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return deserializer.deserializeFloat32();
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

  static void serializeOptionU32(int? value, BinarySerializer serializer) {
    if (value == null) {
      serializer.serializeOptionTag(false);
    } else {
      serializer.serializeOptionTag(true);
      serializer.serializeUint32(value);
    }
  }

  static int? deserializeOptionU32(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
      return deserializer.deserializeUint32();
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

  static void serializeVectorBriefItem(
    List<BriefItem> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      item.serialize(serializer);
    }
  }

  static List<BriefItem> deserializeVectorBriefItem(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => BriefItem.deserialize(deserializer));
  }

  static void serializeVectorCaptureGap(
    List<CaptureGap> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      item.serialize(serializer);
    }
  }

  static List<CaptureGap> deserializeVectorCaptureGap(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => CaptureGap.deserialize(deserializer));
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

  static void serializeVectorMemoryApplyCommit(
    List<MemoryApplyCommit> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      item.serialize(serializer);
    }
  }

  static List<MemoryApplyCommit> deserializeVectorMemoryApplyCommit(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(
      length,
      (_) => MemoryApplyCommit.deserialize(deserializer),
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

  static void serializeVectorRewindFrameRecord(
    List<RewindFrameRecord> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      item.serialize(serializer);
    }
  }

  static List<RewindFrameRecord> deserializeVectorRewindFrameRecord(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(
      length,
      (_) => RewindFrameRecord.deserialize(deserializer),
    );
  }

  static void serializeVectorRewindRetentionOption(
    List<RewindRetentionOption> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      item.serialize(serializer);
    }
  }

  static List<RewindRetentionOption> deserializeVectorRewindRetentionOption(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(
      length,
      (_) => RewindRetentionOption.deserialize(deserializer),
    );
  }

  static void serializeVectorSpeechProfileRecord(
    List<SpeechProfileRecord> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      item.serialize(serializer);
    }
  }

  static List<SpeechProfileRecord> deserializeVectorSpeechProfileRecord(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(
      length,
      (_) => SpeechProfileRecord.deserialize(deserializer),
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

  static void serializeVectorVectorU8(
    List<List<int>> value,
    BinarySerializer serializer,
  ) {
    serializer.serializeLength(value.length);
    for (final item in value) {
      TraitHelpers.serializeVectorU8(item, serializer);
    }
  }

  static List<List<int>> deserializeVectorVectorU8(
    BinaryDeserializer deserializer,
  ) {
    final length = deserializer.deserializeLength();
    return List.generate(
      length,
      (_) => TraitHelpers.deserializeVectorU8(deserializer),
    );
  }
}
