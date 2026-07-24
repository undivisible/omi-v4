// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One cloud memory-log entry packaged as a single-record zkr export commit.
@immutable
class MemoryApplyCommit {
  const MemoryApplyCommit({
    required this.sequence,
    required this.recordedAtMs,
    required this.recordKind,
    required this.recordJson,
  });

  static MemoryApplyCommit deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MemoryApplyCommit(
      sequence: deserializer.deserializeInt64(),
      recordedAtMs: deserializer.deserializeInt64(),
      recordKind: deserializer.deserializeString(),
      recordJson: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MemoryApplyCommit bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MemoryApplyCommit.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int sequence;
  final int recordedAtMs;
  final String recordKind;
  final String recordJson;

  MemoryApplyCommit copyWith({
    int? sequence,
    int? recordedAtMs,
    String? recordKind,
    String? recordJson,
  }) {
    return MemoryApplyCommit(
      sequence: sequence ?? this.sequence,
      recordedAtMs: recordedAtMs ?? this.recordedAtMs,
      recordKind: recordKind ?? this.recordKind,
      recordJson: recordJson ?? this.recordJson,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeInt64(sequence);
    serializer.serializeInt64(recordedAtMs);
    serializer.serializeString(recordKind);
    serializer.serializeString(recordJson);
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

    return other is MemoryApplyCommit &&
        sequence == other.sequence &&
        recordedAtMs == other.recordedAtMs &&
        recordKind == other.recordKind &&
        recordJson == other.recordJson;
  }

  @override
  int get hashCode =>
      Object.hash(sequence, recordedAtMs, recordKind, recordJson);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'sequence: $sequence, '
          'recordedAtMs: $recordedAtMs, '
          'recordKind: $recordKind, '
          'recordJson: $recordJson'
          ')';
      return true;
    }());

    return fullString ?? 'MemoryApplyCommit';
  }
}
