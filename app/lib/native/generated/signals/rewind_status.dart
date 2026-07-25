// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class RewindStatus {
  const RewindStatus({
    required this.enabled,
    required this.paused,
    required this.recording,
    required this.retentionMaxAgeDays,
    required this.retentionMaxBytes,
    required this.retentionOptions,
    required this.deniedBundleIds,
    required this.skipPrivateBrowsing,
    required this.recordWindowTitles,
    required this.readOnScreenText,
    this.lastSkipReason,
    this.lastCaptureAtMs,
    required this.capturedThisSession,
    required this.frameCount,
    required this.totalBytes,
    this.oldestCaptureAtMs,
    required this.permitted,
    required this.locked,
  });

  static RewindStatus deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindStatus(
      enabled: deserializer.deserializeBool(),
      paused: deserializer.deserializeBool(),
      recording: deserializer.deserializeBool(),
      retentionMaxAgeDays: deserializer.deserializeInt64(),
      retentionMaxBytes: deserializer.deserializeUint64(),
      retentionOptions: TraitHelpers.deserializeVectorRewindRetentionOption(
        deserializer,
      ),
      deniedBundleIds: TraitHelpers.deserializeVectorStr(deserializer),
      skipPrivateBrowsing: deserializer.deserializeBool(),
      recordWindowTitles: deserializer.deserializeBool(),
      readOnScreenText: deserializer.deserializeBool(),
      lastSkipReason: TraitHelpers.deserializeOptionRewindSkipReason(
        deserializer,
      ),
      lastCaptureAtMs: TraitHelpers.deserializeOptionI64(deserializer),
      capturedThisSession: deserializer.deserializeUint64(),
      frameCount: deserializer.deserializeUint64(),
      totalBytes: deserializer.deserializeUint64(),
      oldestCaptureAtMs: TraitHelpers.deserializeOptionI64(deserializer),
      permitted: deserializer.deserializeBool(),
      locked: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RewindStatus bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RewindStatus.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final bool enabled;
  final bool paused;
  final bool recording;
  final int retentionMaxAgeDays;
  final Uint64 retentionMaxBytes;
  final List<RewindRetentionOption> retentionOptions;
  final List<String> deniedBundleIds;
  final bool skipPrivateBrowsing;
  final bool recordWindowTitles;
  final bool readOnScreenText;
  final RewindSkipReason? lastSkipReason;
  final int? lastCaptureAtMs;
  final Uint64 capturedThisSession;
  final Uint64 frameCount;
  final Uint64 totalBytes;
  final int? oldestCaptureAtMs;
  final bool permitted;
  final bool locked;

  RewindStatus copyWith({
    bool? enabled,
    bool? paused,
    bool? recording,
    int? retentionMaxAgeDays,
    Uint64? retentionMaxBytes,
    List<RewindRetentionOption>? retentionOptions,
    List<String>? deniedBundleIds,
    bool? skipPrivateBrowsing,
    bool? recordWindowTitles,
    bool? readOnScreenText,
    RewindSkipReason? Function()? lastSkipReason,
    int? Function()? lastCaptureAtMs,
    Uint64? capturedThisSession,
    Uint64? frameCount,
    Uint64? totalBytes,
    int? Function()? oldestCaptureAtMs,
    bool? permitted,
    bool? locked,
  }) {
    return RewindStatus(
      enabled: enabled ?? this.enabled,
      paused: paused ?? this.paused,
      recording: recording ?? this.recording,
      retentionMaxAgeDays: retentionMaxAgeDays ?? this.retentionMaxAgeDays,
      retentionMaxBytes: retentionMaxBytes ?? this.retentionMaxBytes,
      retentionOptions: retentionOptions ?? this.retentionOptions,
      deniedBundleIds: deniedBundleIds ?? this.deniedBundleIds,
      skipPrivateBrowsing: skipPrivateBrowsing ?? this.skipPrivateBrowsing,
      recordWindowTitles: recordWindowTitles ?? this.recordWindowTitles,
      readOnScreenText: readOnScreenText ?? this.readOnScreenText,
      lastSkipReason: lastSkipReason == null
          ? this.lastSkipReason
          : lastSkipReason(),
      lastCaptureAtMs: lastCaptureAtMs == null
          ? this.lastCaptureAtMs
          : lastCaptureAtMs(),
      capturedThisSession: capturedThisSession ?? this.capturedThisSession,
      frameCount: frameCount ?? this.frameCount,
      totalBytes: totalBytes ?? this.totalBytes,
      oldestCaptureAtMs: oldestCaptureAtMs == null
          ? this.oldestCaptureAtMs
          : oldestCaptureAtMs(),
      permitted: permitted ?? this.permitted,
      locked: locked ?? this.locked,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeBool(enabled);
    serializer.serializeBool(paused);
    serializer.serializeBool(recording);
    serializer.serializeInt64(retentionMaxAgeDays);
    serializer.serializeUint64(retentionMaxBytes);
    TraitHelpers.serializeVectorRewindRetentionOption(
      retentionOptions,
      serializer,
    );
    TraitHelpers.serializeVectorStr(deniedBundleIds, serializer);
    serializer.serializeBool(skipPrivateBrowsing);
    serializer.serializeBool(recordWindowTitles);
    serializer.serializeBool(readOnScreenText);
    TraitHelpers.serializeOptionRewindSkipReason(lastSkipReason, serializer);
    TraitHelpers.serializeOptionI64(lastCaptureAtMs, serializer);
    serializer.serializeUint64(capturedThisSession);
    serializer.serializeUint64(frameCount);
    serializer.serializeUint64(totalBytes);
    TraitHelpers.serializeOptionI64(oldestCaptureAtMs, serializer);
    serializer.serializeBool(permitted);
    serializer.serializeBool(locked);
    serializer.decreaseContainerDepth();
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindStatus &&
        enabled == other.enabled &&
        paused == other.paused &&
        recording == other.recording &&
        retentionMaxAgeDays == other.retentionMaxAgeDays &&
        retentionMaxBytes == other.retentionMaxBytes &&
        listEquals(retentionOptions, other.retentionOptions) &&
        listEquals(deniedBundleIds, other.deniedBundleIds) &&
        skipPrivateBrowsing == other.skipPrivateBrowsing &&
        recordWindowTitles == other.recordWindowTitles &&
        readOnScreenText == other.readOnScreenText &&
        lastSkipReason == other.lastSkipReason &&
        lastCaptureAtMs == other.lastCaptureAtMs &&
        capturedThisSession == other.capturedThisSession &&
        frameCount == other.frameCount &&
        totalBytes == other.totalBytes &&
        oldestCaptureAtMs == other.oldestCaptureAtMs &&
        permitted == other.permitted &&
        locked == other.locked;
  }

  @override
  int get hashCode => Object.hash(
    enabled,
    paused,
    recording,
    retentionMaxAgeDays,
    retentionMaxBytes,
    retentionOptions,
    deniedBundleIds,
    skipPrivateBrowsing,
    recordWindowTitles,
    readOnScreenText,
    lastSkipReason,
    lastCaptureAtMs,
    capturedThisSession,
    frameCount,
    totalBytes,
    oldestCaptureAtMs,
    permitted,
    locked,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'enabled: $enabled, '
          'paused: $paused, '
          'recording: $recording, '
          'retentionMaxAgeDays: $retentionMaxAgeDays, '
          'retentionMaxBytes: $retentionMaxBytes, '
          'retentionOptions: $retentionOptions, '
          'deniedBundleIds: $deniedBundleIds, '
          'skipPrivateBrowsing: $skipPrivateBrowsing, '
          'recordWindowTitles: $recordWindowTitles, '
          'readOnScreenText: $readOnScreenText, '
          'lastSkipReason: $lastSkipReason, '
          'lastCaptureAtMs: $lastCaptureAtMs, '
          'capturedThisSession: $capturedThisSession, '
          'frameCount: $frameCount, '
          'totalBytes: $totalBytes, '
          'oldestCaptureAtMs: $oldestCaptureAtMs, '
          'permitted: $permitted, '
          'locked: $locked'
          ')';
      return true;
    }());

    return fullString ?? 'RewindStatus';
  }
}
