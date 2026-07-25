// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// What the write-ahead log is holding, and what the last pass did with it.
///
/// `pending_segments` is what the UI surfaces as "N clips waiting to upload":
/// durability the user cannot see is durability they will not trust.
/// `last_error` is the reason the pass stopped early, and is not fatal — the
/// segments it left behind are still on disk.
@immutable
class CaptureWalState {
  const CaptureWalState({
    required this.requestId,
    required this.pendingSegments,
    required this.pendingBytes,
    this.oldestStartedAtMs,
    required this.uploaded,
    this.lastError,
  });

  static CaptureWalState deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CaptureWalState(
      requestId: deserializer.deserializeString(),
      pendingSegments: deserializer.deserializeUint64(),
      pendingBytes: deserializer.deserializeUint64(),
      oldestStartedAtMs: TraitHelpers.deserializeOptionI64(deserializer),
      uploaded: deserializer.deserializeUint64(),
      lastError: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static CaptureWalState bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CaptureWalState.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final Uint64 pendingSegments;
  final Uint64 pendingBytes;
  final int? oldestStartedAtMs;
  final Uint64 uploaded;
  final String? lastError;

  CaptureWalState copyWith({
    String? requestId,
    Uint64? pendingSegments,
    Uint64? pendingBytes,
    int? Function()? oldestStartedAtMs,
    Uint64? uploaded,
    String? Function()? lastError,
  }) {
    return CaptureWalState(
      requestId: requestId ?? this.requestId,
      pendingSegments: pendingSegments ?? this.pendingSegments,
      pendingBytes: pendingBytes ?? this.pendingBytes,
      oldestStartedAtMs: oldestStartedAtMs == null
          ? this.oldestStartedAtMs
          : oldestStartedAtMs(),
      uploaded: uploaded ?? this.uploaded,
      lastError: lastError == null ? this.lastError : lastError(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeUint64(pendingSegments);
    serializer.serializeUint64(pendingBytes);
    TraitHelpers.serializeOptionI64(oldestStartedAtMs, serializer);
    serializer.serializeUint64(uploaded);
    TraitHelpers.serializeOptionStr(lastError, serializer);
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

    return other is CaptureWalState &&
        requestId == other.requestId &&
        pendingSegments == other.pendingSegments &&
        pendingBytes == other.pendingBytes &&
        oldestStartedAtMs == other.oldestStartedAtMs &&
        uploaded == other.uploaded &&
        lastError == other.lastError;
  }

  @override
  int get hashCode => Object.hash(
    requestId,
    pendingSegments,
    pendingBytes,
    oldestStartedAtMs,
    uploaded,
    lastError,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'pendingSegments: $pendingSegments, '
          'pendingBytes: $pendingBytes, '
          'oldestStartedAtMs: $oldestStartedAtMs, '
          'uploaded: $uploaded, '
          'lastError: $lastError'
          ')';
      return true;
    }());

    return fullString ?? 'CaptureWalState';
  }
}
