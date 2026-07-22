// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class ActionProposal {
  const ActionProposal({
    required this.proposalId,
    required this.requestId,
    required this.title,
    required this.summary,
    required this.risk,
    this.computerAction,
    this.operationId,
    this.actionHash,
    this.targetProvenance,
    this.expiresAtMs,
  });

  static ActionProposal deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ActionProposal(
      proposalId: deserializer.deserializeString(),
      requestId: deserializer.deserializeString(),
      title: deserializer.deserializeString(),
      summary: deserializer.deserializeString(),
      risk: ActionRiskExtension.deserialize(deserializer),
      computerAction: TraitHelpers.deserializeOptionComputerUseAction(
        deserializer,
      ),
      operationId: TraitHelpers.deserializeOptionStr(deserializer),
      actionHash: TraitHelpers.deserializeOptionStr(deserializer),
      targetProvenance:
          TraitHelpers.deserializeOptionComputerUseTargetProvenance(
            deserializer,
          ),
      expiresAtMs: TraitHelpers.deserializeOptionI64(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ActionProposal bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ActionProposal.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String proposalId;
  final String requestId;
  final String title;
  final String summary;
  final ActionRisk risk;
  final ComputerUseAction? computerAction;
  final String? operationId;
  final String? actionHash;
  final ComputerUseTargetProvenance? targetProvenance;
  final int? expiresAtMs;

  ActionProposal copyWith({
    String? proposalId,
    String? requestId,
    String? title,
    String? summary,
    ActionRisk? risk,
    ComputerUseAction? Function()? computerAction,
    String? Function()? operationId,
    String? Function()? actionHash,
    ComputerUseTargetProvenance? Function()? targetProvenance,
    int? Function()? expiresAtMs,
  }) {
    return ActionProposal(
      proposalId: proposalId ?? this.proposalId,
      requestId: requestId ?? this.requestId,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      risk: risk ?? this.risk,
      computerAction: computerAction == null
          ? this.computerAction
          : computerAction(),
      operationId: operationId == null ? this.operationId : operationId(),
      actionHash: actionHash == null ? this.actionHash : actionHash(),
      targetProvenance: targetProvenance == null
          ? this.targetProvenance
          : targetProvenance(),
      expiresAtMs: expiresAtMs == null ? this.expiresAtMs : expiresAtMs(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(proposalId);
    serializer.serializeString(requestId);
    serializer.serializeString(title);
    serializer.serializeString(summary);
    risk.serialize(serializer);
    TraitHelpers.serializeOptionComputerUseAction(computerAction, serializer);
    TraitHelpers.serializeOptionStr(operationId, serializer);
    TraitHelpers.serializeOptionStr(actionHash, serializer);
    TraitHelpers.serializeOptionComputerUseTargetProvenance(
      targetProvenance,
      serializer,
    );
    TraitHelpers.serializeOptionI64(expiresAtMs, serializer);
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

    return other is ActionProposal &&
        proposalId == other.proposalId &&
        requestId == other.requestId &&
        title == other.title &&
        summary == other.summary &&
        risk == other.risk &&
        computerAction == other.computerAction &&
        operationId == other.operationId &&
        actionHash == other.actionHash &&
        targetProvenance == other.targetProvenance &&
        expiresAtMs == other.expiresAtMs;
  }

  @override
  int get hashCode => Object.hash(
    proposalId,
    requestId,
    title,
    summary,
    risk,
    computerAction,
    operationId,
    actionHash,
    targetProvenance,
    expiresAtMs,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'proposalId: $proposalId, '
          'requestId: $requestId, '
          'title: $title, '
          'summary: [REDACTED], '
          'risk: $risk, '
          'computerAction: $computerAction, '
          'operationId: $operationId, '
          'actionHash: $actionHash, '
          'targetProvenance: $targetProvenance, '
          'expiresAtMs: $expiresAtMs'
          ')';
      return true;
    }());

    return fullString ?? 'ActionProposal';
  }
}
