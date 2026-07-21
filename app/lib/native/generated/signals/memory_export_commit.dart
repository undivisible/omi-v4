// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MemoryExportCommit {
  const MemoryExportCommit({
    required this.sequence,
    required this.recordedAtMs,
    required this.eventCount,
    required this.firstEventIndex,
    required this.recordsJson,
  });

  static MemoryExportCommit deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MemoryExportCommit(
      sequence: deserializer.deserializeInt64(),
      recordedAtMs: deserializer.deserializeInt64(),
      eventCount: deserializer.deserializeInt64(),
      firstEventIndex: deserializer.deserializeInt64(),
      recordsJson: TraitHelpers.deserializeVectorStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MemoryExportCommit bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MemoryExportCommit.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int sequence;
  final int recordedAtMs;
  final int eventCount;
  final int firstEventIndex;
  final List<String> recordsJson;

  MemoryExportCommit copyWith({
    int? sequence,
    int? recordedAtMs,
    int? eventCount,
    int? firstEventIndex,
    List<String>? recordsJson,
  }) {
    return MemoryExportCommit(
      sequence: sequence ?? this.sequence,
      recordedAtMs: recordedAtMs ?? this.recordedAtMs,
      eventCount: eventCount ?? this.eventCount,
      firstEventIndex: firstEventIndex ?? this.firstEventIndex,
      recordsJson: recordsJson ?? this.recordsJson,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeInt64(sequence);
    serializer.serializeInt64(recordedAtMs);
    serializer.serializeInt64(eventCount);
    serializer.serializeInt64(firstEventIndex);
    TraitHelpers.serializeVectorStr(recordsJson, serializer);
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

    return other is MemoryExportCommit &&
        sequence == other.sequence &&
        recordedAtMs == other.recordedAtMs &&
        eventCount == other.eventCount &&
        firstEventIndex == other.firstEventIndex &&
        listEquals(recordsJson, other.recordsJson);
  }

  @override
  int get hashCode => Object.hash(
    sequence,
    recordedAtMs,
    eventCount,
    firstEventIndex,
    recordsJson,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'sequence: $sequence, '
          'recordedAtMs: $recordedAtMs, '
          'eventCount: $eventCount, '
          'firstEventIndex: $firstEventIndex, '
          'recordsJson: [REDACTED]'
          ')';
      return true;
    }());

    return fullString ?? 'MemoryExportCommit';
  }
}
