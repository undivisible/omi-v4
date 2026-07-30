// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The Rewind engine's request surface.
///
/// The three capture variants are a strict sequence, and the sequence is the
/// frame-economy invariant: `Tick` carries only what can be sampled without
/// reading a pixel, `PreviewTaken` carries 72 bytes of luminance while the
/// full frame is still held unencoded on the native side, and `FrameEncoded`
/// is only ever sent in answer to [`RewindDirective::Encode`], which the
/// engine only issues once the similarity gate has said keep. Each carries the
/// `step_id` the engine handed out, so a frame can never skip the gate.
abstract class RewindRequest {
  const RewindRequest();

  void serialize(BinarySerializer serializer);

  static RewindRequest deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return RewindRequestOpen.load(deserializer);
      case 1:
        return RewindRequestTick.load(deserializer);
      case 2:
        return RewindRequestPreviewTaken.load(deserializer);
      case 3:
        return RewindRequestFrameEncoded.load(deserializer);
      case 4:
        return RewindRequestSetEnabled.load(deserializer);
      case 5:
        return RewindRequestSetPaused.load(deserializer);
      case 6:
        return RewindRequestSetRetention.load(deserializer);
      case 7:
        return RewindRequestSetPrivacyFlags.load(deserializer);
      case 8:
        return RewindRequestDenyBundleId.load(deserializer);
      case 9:
        return RewindRequestAllowBundleId.load(deserializer);
      case 10:
        return RewindRequestListFrames.load(deserializer);
      case 11:
        return RewindRequestSearch.load(deserializer);
      case 12:
        return RewindRequestDeleteAll.load(deserializer);
      case 13:
        return RewindRequestDeleteLast.load(deserializer);
      case 14:
        return RewindRequestDeleteFrame.load(deserializer);
      case 15:
        return RewindRequestStatus.load(deserializer);
      default:
        throw Exception(
          'Unknown variant index for RewindRequest: ' + index.toString(),
        );
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static RewindRequest bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RewindRequest.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

@immutable
class RewindRequestOpen extends RewindRequest {
  const RewindRequestOpen({required this.root}) : super();

  static RewindRequestOpen load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestOpen(root: deserializer.deserializeString());
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String root;

  RewindRequestOpen copyWith({String? root}) {
    return RewindRequestOpen(root: root ?? this.root);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeString(root);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestOpen && root == other.root;
  }

  @override
  int get hashCode => root.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'root: $root'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestOpen';
  }
}

@immutable
class RewindRequestTick extends RewindRequest {
  const RewindRequestTick({
    required this.context,
    required this.display,
    required this.idleMs,
    required this.locked,
    required this.permitted,
  }) : super();

  static RewindRequestTick load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestTick(
      context: RewindWindowContext.deserialize(deserializer),
      display: RewindDisplay.deserialize(deserializer),
      idleMs: deserializer.deserializeInt64(),
      locked: deserializer.deserializeBool(),
      permitted: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final RewindWindowContext context;
  final RewindDisplay display;
  final int idleMs;
  final bool locked;
  final bool permitted;

  RewindRequestTick copyWith({
    RewindWindowContext? context,
    RewindDisplay? display,
    int? idleMs,
    bool? locked,
    bool? permitted,
  }) {
    return RewindRequestTick(
      context: context ?? this.context,
      display: display ?? this.display,
      idleMs: idleMs ?? this.idleMs,
      locked: locked ?? this.locked,
      permitted: permitted ?? this.permitted,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    context.serialize(serializer);
    display.serialize(serializer);
    serializer.serializeInt64(idleMs);
    serializer.serializeBool(locked);
    serializer.serializeBool(permitted);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestTick &&
        context == other.context &&
        display == other.display &&
        idleMs == other.idleMs &&
        locked == other.locked &&
        permitted == other.permitted;
  }

  @override
  int get hashCode => Object.hash(context, display, idleMs, locked, permitted);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'context: $context, '
          'display: $display, '
          'idleMs: $idleMs, '
          'locked: $locked, '
          'permitted: $permitted'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestTick';
  }
}

@immutable
class RewindRequestPreviewTaken extends RewindRequest {
  const RewindRequestPreviewTaken({required this.stepId, required this.luma})
    : super();

  static RewindRequestPreviewTaken load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestPreviewTaken(
      stepId: deserializer.deserializeUint64(),
      luma: TraitHelpers.deserializeVectorU8(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 stepId;
  final List<int> luma;

  RewindRequestPreviewTaken copyWith({Uint64? stepId, List<int>? luma}) {
    return RewindRequestPreviewTaken(
      stepId: stepId ?? this.stepId,
      luma: luma ?? this.luma,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.serializeUint64(stepId);
    TraitHelpers.serializeVectorU8(luma, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestPreviewTaken &&
        stepId == other.stepId &&
        listEquals(luma, other.luma);
  }

  @override
  int get hashCode => Object.hash(stepId, luma);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'stepId: $stepId, '
          'luma: $luma'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestPreviewTaken';
  }
}

@immutable
class RewindRequestFrameEncoded extends RewindRequest {
  const RewindRequestFrameEncoded({
    required this.stepId,
    required this.jpeg,
    this.ocrText,
  }) : super();

  static RewindRequestFrameEncoded load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestFrameEncoded(
      stepId: deserializer.deserializeUint64(),
      jpeg: TraitHelpers.deserializeVectorU8(deserializer),
      ocrText: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 stepId;
  final List<int> jpeg;
  final String? ocrText;

  RewindRequestFrameEncoded copyWith({
    Uint64? stepId,
    List<int>? jpeg,
    String? Function()? ocrText,
  }) {
    return RewindRequestFrameEncoded(
      stepId: stepId ?? this.stepId,
      jpeg: jpeg ?? this.jpeg,
      ocrText: ocrText == null ? this.ocrText : ocrText(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    serializer.serializeUint64(stepId);
    TraitHelpers.serializeVectorU8(jpeg, serializer);
    TraitHelpers.serializeOptionStr(ocrText, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestFrameEncoded &&
        stepId == other.stepId &&
        listEquals(jpeg, other.jpeg) &&
        ocrText == other.ocrText;
  }

  @override
  int get hashCode => Object.hash(stepId, jpeg, ocrText);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'stepId: $stepId, '
          'jpeg: $jpeg, '
          'ocrText: $ocrText'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestFrameEncoded';
  }
}

@immutable
class RewindRequestSetEnabled extends RewindRequest {
  const RewindRequestSetEnabled({required this.enabled}) : super();

  static RewindRequestSetEnabled load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestSetEnabled(
      enabled: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final bool enabled;

  RewindRequestSetEnabled copyWith({bool? enabled}) {
    return RewindRequestSetEnabled(enabled: enabled ?? this.enabled);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    serializer.serializeBool(enabled);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestSetEnabled && enabled == other.enabled;
  }

  @override
  int get hashCode => enabled.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'enabled: $enabled'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestSetEnabled';
  }
}

@immutable
class RewindRequestSetPaused extends RewindRequest {
  const RewindRequestSetPaused({required this.paused}) : super();

  static RewindRequestSetPaused load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestSetPaused(
      paused: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final bool paused;

  RewindRequestSetPaused copyWith({bool? paused}) {
    return RewindRequestSetPaused(paused: paused ?? this.paused);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    serializer.serializeBool(paused);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestSetPaused && paused == other.paused;
  }

  @override
  int get hashCode => paused.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'paused: $paused'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestSetPaused';
  }
}

@immutable
class RewindRequestSetRetention extends RewindRequest {
  const RewindRequestSetRetention({
    required this.maxAgeDays,
    required this.maxBytes,
  }) : super();

  static RewindRequestSetRetention load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestSetRetention(
      maxAgeDays: deserializer.deserializeInt64(),
      maxBytes: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final int maxAgeDays;
  final Uint64 maxBytes;

  RewindRequestSetRetention copyWith({int? maxAgeDays, Uint64? maxBytes}) {
    return RewindRequestSetRetention(
      maxAgeDays: maxAgeDays ?? this.maxAgeDays,
      maxBytes: maxBytes ?? this.maxBytes,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(6);
    serializer.serializeInt64(maxAgeDays);
    serializer.serializeUint64(maxBytes);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestSetRetention &&
        maxAgeDays == other.maxAgeDays &&
        maxBytes == other.maxBytes;
  }

  @override
  int get hashCode => Object.hash(maxAgeDays, maxBytes);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'maxAgeDays: $maxAgeDays, '
          'maxBytes: $maxBytes'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestSetRetention';
  }
}

@immutable
class RewindRequestSetPrivacyFlags extends RewindRequest {
  const RewindRequestSetPrivacyFlags({
    required this.skipPrivateBrowsing,
    required this.recordWindowTitles,
    required this.readOnScreenText,
  }) : super();

  static RewindRequestSetPrivacyFlags load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestSetPrivacyFlags(
      skipPrivateBrowsing: deserializer.deserializeBool(),
      recordWindowTitles: deserializer.deserializeBool(),
      readOnScreenText: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final bool skipPrivateBrowsing;
  final bool recordWindowTitles;
  final bool readOnScreenText;

  RewindRequestSetPrivacyFlags copyWith({
    bool? skipPrivateBrowsing,
    bool? recordWindowTitles,
    bool? readOnScreenText,
  }) {
    return RewindRequestSetPrivacyFlags(
      skipPrivateBrowsing: skipPrivateBrowsing ?? this.skipPrivateBrowsing,
      recordWindowTitles: recordWindowTitles ?? this.recordWindowTitles,
      readOnScreenText: readOnScreenText ?? this.readOnScreenText,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(7);
    serializer.serializeBool(skipPrivateBrowsing);
    serializer.serializeBool(recordWindowTitles);
    serializer.serializeBool(readOnScreenText);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestSetPrivacyFlags &&
        skipPrivateBrowsing == other.skipPrivateBrowsing &&
        recordWindowTitles == other.recordWindowTitles &&
        readOnScreenText == other.readOnScreenText;
  }

  @override
  int get hashCode =>
      Object.hash(skipPrivateBrowsing, recordWindowTitles, readOnScreenText);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'skipPrivateBrowsing: $skipPrivateBrowsing, '
          'recordWindowTitles: $recordWindowTitles, '
          'readOnScreenText: $readOnScreenText'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestSetPrivacyFlags';
  }
}

@immutable
class RewindRequestDenyBundleId extends RewindRequest {
  const RewindRequestDenyBundleId({required this.bundleId}) : super();

  static RewindRequestDenyBundleId load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestDenyBundleId(
      bundleId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String bundleId;

  RewindRequestDenyBundleId copyWith({String? bundleId}) {
    return RewindRequestDenyBundleId(bundleId: bundleId ?? this.bundleId);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(8);
    serializer.serializeString(bundleId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestDenyBundleId && bundleId == other.bundleId;
  }

  @override
  int get hashCode => bundleId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'bundleId: $bundleId'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestDenyBundleId';
  }
}

@immutable
class RewindRequestAllowBundleId extends RewindRequest {
  const RewindRequestAllowBundleId({required this.bundleId}) : super();

  static RewindRequestAllowBundleId load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestAllowBundleId(
      bundleId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String bundleId;

  RewindRequestAllowBundleId copyWith({String? bundleId}) {
    return RewindRequestAllowBundleId(bundleId: bundleId ?? this.bundleId);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(9);
    serializer.serializeString(bundleId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestAllowBundleId && bundleId == other.bundleId;
  }

  @override
  int get hashCode => bundleId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'bundleId: $bundleId'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestAllowBundleId';
  }
}

@immutable
class RewindRequestListFrames extends RewindRequest {
  const RewindRequestListFrames({required this.limit}) : super();

  static RewindRequestListFrames load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestListFrames(
      limit: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final int limit;

  RewindRequestListFrames copyWith({int? limit}) {
    return RewindRequestListFrames(limit: limit ?? this.limit);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(10);
    serializer.serializeUint32(limit);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestListFrames && limit == other.limit;
  }

  @override
  int get hashCode => limit.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'limit: $limit'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestListFrames';
  }
}

@immutable
class RewindRequestSearch extends RewindRequest {
  const RewindRequestSearch({required this.query, required this.limit})
    : super();

  static RewindRequestSearch load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestSearch(
      query: deserializer.deserializeString(),
      limit: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String query;
  final int limit;

  RewindRequestSearch copyWith({String? query, int? limit}) {
    return RewindRequestSearch(
      query: query ?? this.query,
      limit: limit ?? this.limit,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(11);
    serializer.serializeString(query);
    serializer.serializeUint32(limit);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestSearch &&
        query == other.query &&
        limit == other.limit;
  }

  @override
  int get hashCode => Object.hash(query, limit);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'query: $query, '
          'limit: $limit'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestSearch';
  }
}

@immutable
class RewindRequestDeleteAll extends RewindRequest {
  const RewindRequestDeleteAll() : super();

  static RewindRequestDeleteAll load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestDeleteAll();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(12);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestDeleteAll;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestDeleteAll';
  }
}

@immutable
class RewindRequestDeleteLast extends RewindRequest {
  const RewindRequestDeleteLast({required this.windowMs}) : super();

  static RewindRequestDeleteLast load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestDeleteLast(
      windowMs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final int windowMs;

  RewindRequestDeleteLast copyWith({int? windowMs}) {
    return RewindRequestDeleteLast(windowMs: windowMs ?? this.windowMs);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(13);
    serializer.serializeInt64(windowMs);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestDeleteLast && windowMs == other.windowMs;
  }

  @override
  int get hashCode => windowMs.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'windowMs: $windowMs'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestDeleteLast';
  }
}

@immutable
class RewindRequestDeleteFrame extends RewindRequest {
  const RewindRequestDeleteFrame({required this.relativePath}) : super();

  static RewindRequestDeleteFrame load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestDeleteFrame(
      relativePath: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String relativePath;

  RewindRequestDeleteFrame copyWith({String? relativePath}) {
    return RewindRequestDeleteFrame(
      relativePath: relativePath ?? this.relativePath,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(14);
    serializer.serializeString(relativePath);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestDeleteFrame &&
        relativePath == other.relativePath;
  }

  @override
  int get hashCode => relativePath.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'relativePath: $relativePath'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestDeleteFrame';
  }
}

@immutable
class RewindRequestStatus extends RewindRequest {
  const RewindRequestStatus() : super();

  static RewindRequestStatus load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRequestStatus();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(15);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindRequestStatus;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          ')';
      return true;
    }());

    return fullString ?? 'RewindRequestStatus';
  }
}
