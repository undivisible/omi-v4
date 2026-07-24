// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class ComputerUseAuthorityReceipt {
  const ComputerUseAuthorityReceipt({
    required this.version,
    required this.executionId,
    required this.receiptId,
    required this.receiptToken,
    required this.firebaseToken,
    required this.subject,
    required this.policyGeneration,
    required this.operationId,
    required this.proposalId,
    required this.actionHash,
    required this.risk,
    required this.issuedAtMs,
    required this.expiresAtMs,
  });

  static ComputerUseAuthorityReceipt deserialize(
    BinaryDeserializer deserializer,
  ) {
    deserializer.increaseContainerDepth();
    final instance = ComputerUseAuthorityReceipt(
      version: deserializer.deserializeString(),
      executionId: deserializer.deserializeString(),
      receiptId: deserializer.deserializeString(),
      receiptToken: deserializer.deserializeString(),
      firebaseToken: deserializer.deserializeString(),
      subject: deserializer.deserializeString(),
      policyGeneration: deserializer.deserializeUint64(),
      operationId: deserializer.deserializeString(),
      proposalId: deserializer.deserializeString(),
      actionHash: deserializer.deserializeString(),
      risk: ActionRiskExtension.deserialize(deserializer),
      issuedAtMs: deserializer.deserializeInt64(),
      expiresAtMs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ComputerUseAuthorityReceipt bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ComputerUseAuthorityReceipt.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String version;
  final String executionId;
  final String receiptId;
  final String receiptToken;
  final String firebaseToken;
  final String subject;
  final Uint64 policyGeneration;
  final String operationId;
  final String proposalId;
  final String actionHash;
  final ActionRisk risk;
  final int issuedAtMs;
  final int expiresAtMs;

  ComputerUseAuthorityReceipt copyWith({
    String? version,
    String? executionId,
    String? receiptId,
    String? receiptToken,
    String? firebaseToken,
    String? subject,
    Uint64? policyGeneration,
    String? operationId,
    String? proposalId,
    String? actionHash,
    ActionRisk? risk,
    int? issuedAtMs,
    int? expiresAtMs,
  }) {
    return ComputerUseAuthorityReceipt(
      version: version ?? this.version,
      executionId: executionId ?? this.executionId,
      receiptId: receiptId ?? this.receiptId,
      receiptToken: receiptToken ?? this.receiptToken,
      firebaseToken: firebaseToken ?? this.firebaseToken,
      subject: subject ?? this.subject,
      policyGeneration: policyGeneration ?? this.policyGeneration,
      operationId: operationId ?? this.operationId,
      proposalId: proposalId ?? this.proposalId,
      actionHash: actionHash ?? this.actionHash,
      risk: risk ?? this.risk,
      issuedAtMs: issuedAtMs ?? this.issuedAtMs,
      expiresAtMs: expiresAtMs ?? this.expiresAtMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(version);
    serializer.serializeString(executionId);
    serializer.serializeString(receiptId);
    serializer.serializeString(receiptToken);
    serializer.serializeString(firebaseToken);
    serializer.serializeString(subject);
    serializer.serializeUint64(policyGeneration);
    serializer.serializeString(operationId);
    serializer.serializeString(proposalId);
    serializer.serializeString(actionHash);
    risk.serialize(serializer);
    serializer.serializeInt64(issuedAtMs);
    serializer.serializeInt64(expiresAtMs);
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

    return other is ComputerUseAuthorityReceipt &&
        version == other.version &&
        executionId == other.executionId &&
        receiptId == other.receiptId &&
        receiptToken == other.receiptToken &&
        firebaseToken == other.firebaseToken &&
        subject == other.subject &&
        policyGeneration == other.policyGeneration &&
        operationId == other.operationId &&
        proposalId == other.proposalId &&
        actionHash == other.actionHash &&
        risk == other.risk &&
        issuedAtMs == other.issuedAtMs &&
        expiresAtMs == other.expiresAtMs;
  }

  @override
  int get hashCode => Object.hash(
    version,
    executionId,
    receiptId,
    receiptToken,
    firebaseToken,
    subject,
    policyGeneration,
    operationId,
    proposalId,
    actionHash,
    risk,
    issuedAtMs,
    expiresAtMs,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'version: $version, '
          'executionId: $executionId, '
          'receiptId: $receiptId, '
          'receiptToken: [REDACTED], '
          'firebaseToken: [REDACTED], '
          'subject: [REDACTED], '
          'policyGeneration: $policyGeneration, '
          'operationId: $operationId, '
          'proposalId: $proposalId, '
          'actionHash: $actionHash, '
          'risk: $risk, '
          'issuedAtMs: $issuedAtMs, '
          'expiresAtMs: $expiresAtMs'
          ')';
      return true;
    }());

    return fullString ?? 'ComputerUseAuthorityReceipt';
  }
}
