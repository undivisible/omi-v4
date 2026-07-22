// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class RuntimeStatus {
  const RuntimeStatus({
    required this.phase,
    this.detail,
    required this.computerUseAvailable,
    this.computerUseCapabilities,
    required this.localAiAvailable,
    required this.memoryAvailable,
    required this.agentHarnessAvailable,
  });

  static RuntimeStatus deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RuntimeStatus(
      phase: RuntimePhaseExtension.deserialize(deserializer),
      detail: TraitHelpers.deserializeOptionStr(deserializer),
      computerUseAvailable: deserializer.deserializeBool(),
      computerUseCapabilities:
          TraitHelpers.deserializeOptionComputerUseCapabilities(deserializer),
      localAiAvailable: deserializer.deserializeBool(),
      memoryAvailable: deserializer.deserializeBool(),
      agentHarnessAvailable: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RuntimeStatus bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RuntimeStatus.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final RuntimePhase phase;
  final String? detail;
  final bool computerUseAvailable;
  final ComputerUseCapabilities? computerUseCapabilities;
  final bool localAiAvailable;
  final bool memoryAvailable;
  final bool agentHarnessAvailable;

  RuntimeStatus copyWith({
    RuntimePhase? phase,
    String? Function()? detail,
    bool? computerUseAvailable,
    ComputerUseCapabilities? Function()? computerUseCapabilities,
    bool? localAiAvailable,
    bool? memoryAvailable,
    bool? agentHarnessAvailable,
  }) {
    return RuntimeStatus(
      phase: phase ?? this.phase,
      detail: detail == null ? this.detail : detail(),
      computerUseAvailable: computerUseAvailable ?? this.computerUseAvailable,
      computerUseCapabilities: computerUseCapabilities == null
          ? this.computerUseCapabilities
          : computerUseCapabilities(),
      localAiAvailable: localAiAvailable ?? this.localAiAvailable,
      memoryAvailable: memoryAvailable ?? this.memoryAvailable,
      agentHarnessAvailable:
          agentHarnessAvailable ?? this.agentHarnessAvailable,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    phase.serialize(serializer);
    TraitHelpers.serializeOptionStr(detail, serializer);
    serializer.serializeBool(computerUseAvailable);
    TraitHelpers.serializeOptionComputerUseCapabilities(
      computerUseCapabilities,
      serializer,
    );
    serializer.serializeBool(localAiAvailable);
    serializer.serializeBool(memoryAvailable);
    serializer.serializeBool(agentHarnessAvailable);
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

    return other is RuntimeStatus &&
        phase == other.phase &&
        detail == other.detail &&
        computerUseAvailable == other.computerUseAvailable &&
        computerUseCapabilities == other.computerUseCapabilities &&
        localAiAvailable == other.localAiAvailable &&
        memoryAvailable == other.memoryAvailable &&
        agentHarnessAvailable == other.agentHarnessAvailable;
  }

  @override
  int get hashCode => Object.hash(
    phase,
    detail,
    computerUseAvailable,
    computerUseCapabilities,
    localAiAvailable,
    memoryAvailable,
    agentHarnessAvailable,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'phase: $phase, '
          'detail: $detail, '
          'computerUseAvailable: $computerUseAvailable, '
          'computerUseCapabilities: $computerUseCapabilities, '
          'localAiAvailable: $localAiAvailable, '
          'memoryAvailable: $memoryAvailable, '
          'agentHarnessAvailable: $agentHarnessAvailable'
          ')';
      return true;
    }());

    return fullString ?? 'RuntimeStatus';
  }
}
