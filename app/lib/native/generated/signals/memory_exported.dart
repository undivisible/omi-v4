// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MemoryExported {
  const MemoryExported({
    required this.requestId,
    required this.exportFormat,
    required this.databaseSchemaVersion,
    required this.highWaterMark,
    required this.nextAfterCommit,
    required this.nextAfterEventIndex,
    required this.complete,
    required this.commits,
  });

  static MemoryExported deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MemoryExported(
      requestId: deserializer.deserializeString(),
      exportFormat: deserializer.deserializeUint32(),
      databaseSchemaVersion: deserializer.deserializeInt64(),
      highWaterMark: deserializer.deserializeInt64(),
      nextAfterCommit: deserializer.deserializeInt64(),
      nextAfterEventIndex: deserializer.deserializeInt64(),
      complete: deserializer.deserializeBool(),
      commits: TraitHelpers.deserializeVectorMemoryExportCommit(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MemoryExported bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MemoryExported.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final int exportFormat;
  final int databaseSchemaVersion;
  final int highWaterMark;
  final int nextAfterCommit;
  final int nextAfterEventIndex;
  final bool complete;
  final List<MemoryExportCommit> commits;

  MemoryExported copyWith({
    String? requestId,
    int? exportFormat,
    int? databaseSchemaVersion,
    int? highWaterMark,
    int? nextAfterCommit,
    int? nextAfterEventIndex,
    bool? complete,
    List<MemoryExportCommit>? commits,
  }) {
    return MemoryExported(
      requestId: requestId ?? this.requestId,
      exportFormat: exportFormat ?? this.exportFormat,
      databaseSchemaVersion:
          databaseSchemaVersion ?? this.databaseSchemaVersion,
      highWaterMark: highWaterMark ?? this.highWaterMark,
      nextAfterCommit: nextAfterCommit ?? this.nextAfterCommit,
      nextAfterEventIndex: nextAfterEventIndex ?? this.nextAfterEventIndex,
      complete: complete ?? this.complete,
      commits: commits ?? this.commits,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeUint32(exportFormat);
    serializer.serializeInt64(databaseSchemaVersion);
    serializer.serializeInt64(highWaterMark);
    serializer.serializeInt64(nextAfterCommit);
    serializer.serializeInt64(nextAfterEventIndex);
    serializer.serializeBool(complete);
    TraitHelpers.serializeVectorMemoryExportCommit(commits, serializer);
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

    return other is MemoryExported &&
        requestId == other.requestId &&
        exportFormat == other.exportFormat &&
        databaseSchemaVersion == other.databaseSchemaVersion &&
        highWaterMark == other.highWaterMark &&
        nextAfterCommit == other.nextAfterCommit &&
        nextAfterEventIndex == other.nextAfterEventIndex &&
        complete == other.complete &&
        listEquals(commits, other.commits);
  }

  @override
  int get hashCode => Object.hash(
    requestId,
    exportFormat,
    databaseSchemaVersion,
    highWaterMark,
    nextAfterCommit,
    nextAfterEventIndex,
    complete,
    commits,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'exportFormat: $exportFormat, '
          'databaseSchemaVersion: $databaseSchemaVersion, '
          'highWaterMark: $highWaterMark, '
          'nextAfterCommit: $nextAfterCommit, '
          'nextAfterEventIndex: $nextAfterEventIndex, '
          'complete: $complete, '
          'commits: $commits'
          ')';
      return true;
    }());

    return fullString ?? 'MemoryExported';
  }
}
