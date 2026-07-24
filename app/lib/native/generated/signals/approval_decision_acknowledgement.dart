// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class ApprovalDecisionAcknowledgement {
  const ApprovalDecisionAcknowledgement({
    required this.requestId,
    required this.proposalId,
    required this.decision,
    required this.accepted,
    required this.executionPending,
  });

  static ApprovalDecisionAcknowledgement deserialize(
    BinaryDeserializer deserializer,
  ) {
    deserializer.increaseContainerDepth();
    final instance = ApprovalDecisionAcknowledgement(
      requestId: deserializer.deserializeString(),
      proposalId: deserializer.deserializeString(),
      decision: ApprovalDecisionExtension.deserialize(deserializer),
      accepted: deserializer.deserializeBool(),
      executionPending: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ApprovalDecisionAcknowledgement bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ApprovalDecisionAcknowledgement.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String proposalId;
  final ApprovalDecision decision;
  final bool accepted;
  final bool executionPending;

  ApprovalDecisionAcknowledgement copyWith({
    String? requestId,
    String? proposalId,
    ApprovalDecision? decision,
    bool? accepted,
    bool? executionPending,
  }) {
    return ApprovalDecisionAcknowledgement(
      requestId: requestId ?? this.requestId,
      proposalId: proposalId ?? this.proposalId,
      decision: decision ?? this.decision,
      accepted: accepted ?? this.accepted,
      executionPending: executionPending ?? this.executionPending,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeString(proposalId);
    decision.serialize(serializer);
    serializer.serializeBool(accepted);
    serializer.serializeBool(executionPending);
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

    return other is ApprovalDecisionAcknowledgement &&
        requestId == other.requestId &&
        proposalId == other.proposalId &&
        decision == other.decision &&
        accepted == other.accepted &&
        executionPending == other.executionPending;
  }

  @override
  int get hashCode =>
      Object.hash(requestId, proposalId, decision, accepted, executionPending);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'proposalId: $proposalId, '
          'decision: $decision, '
          'accepted: $accepted, '
          'executionPending: $executionPending'
          ')';
      return true;
    }());

    return fullString ?? 'ApprovalDecisionAcknowledgement';
  }
}
