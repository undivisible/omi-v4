// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class ComputerUseTargetProvenance {
  const ComputerUseTargetProvenance({
    required this.processId,
    required this.processGeneration,
    required this.windowId,
    required this.role,
    required this.observationGeneration,
  });

  static ComputerUseTargetProvenance deserialize(
    BinaryDeserializer deserializer,
  ) {
    deserializer.increaseContainerDepth();
    final instance = ComputerUseTargetProvenance(
      processId: deserializer.deserializeUint32(),
      processGeneration: deserializer.deserializeString(),
      windowId: deserializer.deserializeString(),
      role: deserializer.deserializeString(),
      observationGeneration: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ComputerUseTargetProvenance bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ComputerUseTargetProvenance.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int processId;
  final String processGeneration;
  final String windowId;
  final String role;
  final Uint64 observationGeneration;

  ComputerUseTargetProvenance copyWith({
    int? processId,
    String? processGeneration,
    String? windowId,
    String? role,
    Uint64? observationGeneration,
  }) {
    return ComputerUseTargetProvenance(
      processId: processId ?? this.processId,
      processGeneration: processGeneration ?? this.processGeneration,
      windowId: windowId ?? this.windowId,
      role: role ?? this.role,
      observationGeneration:
          observationGeneration ?? this.observationGeneration,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(processId);
    serializer.serializeString(processGeneration);
    serializer.serializeString(windowId);
    serializer.serializeString(role);
    serializer.serializeUint64(observationGeneration);
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

    return other is ComputerUseTargetProvenance &&
        processId == other.processId &&
        processGeneration == other.processGeneration &&
        windowId == other.windowId &&
        role == other.role &&
        observationGeneration == other.observationGeneration;
  }

  @override
  int get hashCode => Object.hash(
    processId,
    processGeneration,
    windowId,
    role,
    observationGeneration,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'processId: [REDACTED], '
          'processGeneration: [REDACTED], '
          'windowId: [REDACTED], '
          'role: $role, '
          'observationGeneration: $observationGeneration'
          ')';
      return true;
    }());

    return fullString ?? 'ComputerUseTargetProvenance';
  }
}
