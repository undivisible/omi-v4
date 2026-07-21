// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class ApprovalExecutionAcknowledgement {
  const ApprovalExecutionAcknowledgement({
    required this.requestId,
    required this.proposalId,
    required this.accepted,
  });

  static ApprovalExecutionAcknowledgement deserialize(
    BinaryDeserializer deserializer,
  ) {
    deserializer.increaseContainerDepth();
    final instance = ApprovalExecutionAcknowledgement(
      requestId: deserializer.deserializeString(),
      proposalId: deserializer.deserializeString(),
      accepted: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ApprovalExecutionAcknowledgement bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ApprovalExecutionAcknowledgement.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String proposalId;
  final bool accepted;

  ApprovalExecutionAcknowledgement copyWith({
    String? requestId,
    String? proposalId,
    bool? accepted,
  }) {
    return ApprovalExecutionAcknowledgement(
      requestId: requestId ?? this.requestId,
      proposalId: proposalId ?? this.proposalId,
      accepted: accepted ?? this.accepted,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeString(proposalId);
    serializer.serializeBool(accepted);
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

    return other is ApprovalExecutionAcknowledgement &&
        requestId == other.requestId &&
        proposalId == other.proposalId &&
        accepted == other.accepted;
  }

  @override
  int get hashCode => Object.hash(requestId, proposalId, accepted);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'proposalId: $proposalId, '
          'accepted: $accepted'
          ')';
      return true;
    }());

    return fullString ?? 'ApprovalExecutionAcknowledgement';
  }
}
