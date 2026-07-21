// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

abstract class Command {
  const Command();

  void serialize(BinarySerializer serializer);

  static Command deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return CommandConfigureMemory.load(deserializer);
      case 1:
        return CommandSendMessage.load(deserializer);
      case 2:
        return CommandConfigureAssistant.load(deserializer);
      case 3:
        return CommandConfigureTrustedAssistant.load(deserializer);
      case 4:
        return CommandClearAssistant.load(deserializer);
      case 5:
        return CommandStartTranscription.load(deserializer);
      case 6:
        return CommandStopTranscription.load(deserializer);
      case 7:
        return CommandApproveAndExecuteComputerUse.load(deserializer);
      case 8:
        return CommandCaptureEvent.load(deserializer);
      case 9:
        return CommandSearchMemory.load(deserializer);
      case 10:
        return CommandCorrectMemory.load(deserializer);
      case 11:
        return CommandDeleteMemorySource.load(deserializer);
      case 12:
        return CommandApprovalDecision.load(deserializer);
      case 13:
        return CommandDeviceState.load(deserializer);
      case 14:
        return CommandCancel.load(deserializer);
      default:
        throw Exception(
          'Unknown variant index for Command: ' + index.toString(),
        );
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static Command bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = Command.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

@immutable
class CommandConfigureMemory extends Command {
  const CommandConfigureMemory({
    required this.databasePath,
    required this.tenantId,
    required this.personId,
  }) : super();

  static CommandConfigureMemory load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandConfigureMemory(
      databasePath: deserializer.deserializeString(),
      tenantId: deserializer.deserializeString(),
      personId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String databasePath;
  final String tenantId;
  final String personId;

  CommandConfigureMemory copyWith({
    String? databasePath,
    String? tenantId,
    String? personId,
  }) {
    return CommandConfigureMemory(
      databasePath: databasePath ?? this.databasePath,
      tenantId: tenantId ?? this.tenantId,
      personId: personId ?? this.personId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeString(databasePath);
    serializer.serializeString(tenantId);
    serializer.serializeString(personId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandConfigureMemory &&
        databasePath == other.databasePath &&
        tenantId == other.tenantId &&
        personId == other.personId;
  }

  @override
  int get hashCode => Object.hash(databasePath, tenantId, personId);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'databasePath: $databasePath, '
          'tenantId: $tenantId, '
          'personId: $personId'
          ')';
      return true;
    }());

    return fullString ?? 'CommandConfigureMemory';
  }
}

@immutable
class CommandSendMessage extends Command {
  const CommandSendMessage({required this.text, this.conversationId}) : super();

  static CommandSendMessage load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandSendMessage(
      text: deserializer.deserializeString(),
      conversationId: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String text;
  final String? conversationId;

  CommandSendMessage copyWith({
    String? text,
    String? Function()? conversationId,
  }) {
    return CommandSendMessage(
      text: text ?? this.text,
      conversationId: conversationId == null
          ? this.conversationId
          : conversationId(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(text);
    TraitHelpers.serializeOptionStr(conversationId, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandSendMessage &&
        text == other.text &&
        conversationId == other.conversationId;
  }

  @override
  int get hashCode => Object.hash(text, conversationId);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'text: [REDACTED], '
          'conversationId: $conversationId'
          ')';
      return true;
    }());

    return fullString ?? 'CommandSendMessage';
  }
}

@immutable
class CommandConfigureAssistant extends Command {
  const CommandConfigureAssistant({
    required this.provider,
    required this.model,
    this.endpoint,
    required this.credential,
  }) : super();

  static CommandConfigureAssistant load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandConfigureAssistant(
      provider: AssistantProviderExtension.deserialize(deserializer),
      model: deserializer.deserializeString(),
      endpoint: TraitHelpers.deserializeOptionStr(deserializer),
      credential: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final AssistantProvider provider;
  final String model;
  final String? endpoint;
  final String credential;

  CommandConfigureAssistant copyWith({
    AssistantProvider? provider,
    String? model,
    String? Function()? endpoint,
    String? credential,
  }) {
    return CommandConfigureAssistant(
      provider: provider ?? this.provider,
      model: model ?? this.model,
      endpoint: endpoint == null ? this.endpoint : endpoint(),
      credential: credential ?? this.credential,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    provider.serialize(serializer);
    serializer.serializeString(model);
    TraitHelpers.serializeOptionStr(endpoint, serializer);
    serializer.serializeString(credential);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandConfigureAssistant &&
        provider == other.provider &&
        model == other.model &&
        endpoint == other.endpoint &&
        credential == other.credential;
  }

  @override
  int get hashCode => Object.hash(provider, model, endpoint, credential);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'provider: $provider, '
          'model: $model, '
          'endpoint: $endpoint, '
          'credential: [REDACTED]'
          ')';
      return true;
    }());

    return fullString ?? 'CommandConfigureAssistant';
  }
}

@immutable
class CommandConfigureTrustedAssistant extends Command {
  const CommandConfigureTrustedAssistant({required this.managedWorkerOrigin})
    : super();

  static CommandConfigureTrustedAssistant load(
    BinaryDeserializer deserializer,
  ) {
    deserializer.increaseContainerDepth();
    final instance = CommandConfigureTrustedAssistant(
      managedWorkerOrigin: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String managedWorkerOrigin;

  CommandConfigureTrustedAssistant copyWith({String? managedWorkerOrigin}) {
    return CommandConfigureTrustedAssistant(
      managedWorkerOrigin: managedWorkerOrigin ?? this.managedWorkerOrigin,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    serializer.serializeString(managedWorkerOrigin);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandConfigureTrustedAssistant &&
        managedWorkerOrigin == other.managedWorkerOrigin;
  }

  @override
  int get hashCode => managedWorkerOrigin.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'managedWorkerOrigin: $managedWorkerOrigin'
          ')';
      return true;
    }());

    return fullString ?? 'CommandConfigureTrustedAssistant';
  }
}

@immutable
class CommandClearAssistant extends Command {
  const CommandClearAssistant() : super();

  static CommandClearAssistant load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandClearAssistant();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandClearAssistant;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          ')';
      return true;
    }());

    return fullString ?? 'CommandClearAssistant';
  }
}

@immutable
class CommandStartTranscription extends Command {
  const CommandStartTranscription({
    required this.audioStreamId,
    required this.deviceId,
    required this.auth,
    required this.language,
    required this.sampleRateHz,
    required this.channels,
    required this.encoding,
  }) : super();

  static CommandStartTranscription load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandStartTranscription(
      audioStreamId: deserializer.deserializeString(),
      deviceId: deserializer.deserializeString(),
      auth: TranscriptionAuth.deserialize(deserializer),
      language: deserializer.deserializeString(),
      sampleRateHz: deserializer.deserializeUint32(),
      channels: deserializer.deserializeUint8(),
      encoding: AudioEncodingExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String audioStreamId;
  final String deviceId;
  final TranscriptionAuth auth;
  final String language;
  final int sampleRateHz;
  final int channels;
  final AudioEncoding encoding;

  CommandStartTranscription copyWith({
    String? audioStreamId,
    String? deviceId,
    TranscriptionAuth? auth,
    String? language,
    int? sampleRateHz,
    int? channels,
    AudioEncoding? encoding,
  }) {
    return CommandStartTranscription(
      audioStreamId: audioStreamId ?? this.audioStreamId,
      deviceId: deviceId ?? this.deviceId,
      auth: auth ?? this.auth,
      language: language ?? this.language,
      sampleRateHz: sampleRateHz ?? this.sampleRateHz,
      channels: channels ?? this.channels,
      encoding: encoding ?? this.encoding,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    serializer.serializeString(audioStreamId);
    serializer.serializeString(deviceId);
    auth.serialize(serializer);
    serializer.serializeString(language);
    serializer.serializeUint32(sampleRateHz);
    serializer.serializeUint8(channels);
    encoding.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandStartTranscription &&
        audioStreamId == other.audioStreamId &&
        deviceId == other.deviceId &&
        auth == other.auth &&
        language == other.language &&
        sampleRateHz == other.sampleRateHz &&
        channels == other.channels &&
        encoding == other.encoding;
  }

  @override
  int get hashCode => Object.hash(
    audioStreamId,
    deviceId,
    auth,
    language,
    sampleRateHz,
    channels,
    encoding,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'audioStreamId: $audioStreamId, '
          'deviceId: $deviceId, '
          'auth: $auth, '
          'language: $language, '
          'sampleRateHz: $sampleRateHz, '
          'channels: $channels, '
          'encoding: $encoding'
          ')';
      return true;
    }());

    return fullString ?? 'CommandStartTranscription';
  }
}

@immutable
class CommandStopTranscription extends Command {
  const CommandStopTranscription({required this.audioStreamId}) : super();

  static CommandStopTranscription load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandStopTranscription(
      audioStreamId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String audioStreamId;

  CommandStopTranscription copyWith({String? audioStreamId}) {
    return CommandStopTranscription(
      audioStreamId: audioStreamId ?? this.audioStreamId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(6);
    serializer.serializeString(audioStreamId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandStopTranscription &&
        audioStreamId == other.audioStreamId;
  }

  @override
  int get hashCode => audioStreamId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'audioStreamId: $audioStreamId'
          ')';
      return true;
    }());

    return fullString ?? 'CommandStopTranscription';
  }
}

@immutable
class CommandApproveAndExecuteComputerUse extends Command {
  const CommandApproveAndExecuteComputerUse({required this.proposalId})
    : super();

  static CommandApproveAndExecuteComputerUse load(
    BinaryDeserializer deserializer,
  ) {
    deserializer.increaseContainerDepth();
    final instance = CommandApproveAndExecuteComputerUse(
      proposalId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String proposalId;

  CommandApproveAndExecuteComputerUse copyWith({String? proposalId}) {
    return CommandApproveAndExecuteComputerUse(
      proposalId: proposalId ?? this.proposalId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(7);
    serializer.serializeString(proposalId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandApproveAndExecuteComputerUse &&
        proposalId == other.proposalId;
  }

  @override
  int get hashCode => proposalId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'proposalId: $proposalId'
          ')';
      return true;
    }());

    return fullString ?? 'CommandApproveAndExecuteComputerUse';
  }
}

@immutable
class CommandCaptureEvent extends Command {
  const CommandCaptureEvent({
    required this.ingestionKey,
    required this.source,
    required this.occurredAtMs,
    required this.recordedAtMs,
    this.text,
    this.application,
    this.windowTitle,
    this.transcriptLocator,
  }) : super();

  static CommandCaptureEvent load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandCaptureEvent(
      ingestionKey: deserializer.deserializeString(),
      source: CaptureSourceExtension.deserialize(deserializer),
      occurredAtMs: deserializer.deserializeInt64(),
      recordedAtMs: deserializer.deserializeInt64(),
      text: TraitHelpers.deserializeOptionStr(deserializer),
      application: TraitHelpers.deserializeOptionStr(deserializer),
      windowTitle: TraitHelpers.deserializeOptionStr(deserializer),
      transcriptLocator: TraitHelpers.deserializeOptionTranscriptLocator(
        deserializer,
      ),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String ingestionKey;
  final CaptureSource source;
  final int occurredAtMs;
  final int recordedAtMs;
  final String? text;
  final String? application;
  final String? windowTitle;
  final TranscriptLocator? transcriptLocator;

  CommandCaptureEvent copyWith({
    String? ingestionKey,
    CaptureSource? source,
    int? occurredAtMs,
    int? recordedAtMs,
    String? Function()? text,
    String? Function()? application,
    String? Function()? windowTitle,
    TranscriptLocator? Function()? transcriptLocator,
  }) {
    return CommandCaptureEvent(
      ingestionKey: ingestionKey ?? this.ingestionKey,
      source: source ?? this.source,
      occurredAtMs: occurredAtMs ?? this.occurredAtMs,
      recordedAtMs: recordedAtMs ?? this.recordedAtMs,
      text: text == null ? this.text : text(),
      application: application == null ? this.application : application(),
      windowTitle: windowTitle == null ? this.windowTitle : windowTitle(),
      transcriptLocator: transcriptLocator == null
          ? this.transcriptLocator
          : transcriptLocator(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(8);
    serializer.serializeString(ingestionKey);
    source.serialize(serializer);
    serializer.serializeInt64(occurredAtMs);
    serializer.serializeInt64(recordedAtMs);
    TraitHelpers.serializeOptionStr(text, serializer);
    TraitHelpers.serializeOptionStr(application, serializer);
    TraitHelpers.serializeOptionStr(windowTitle, serializer);
    TraitHelpers.serializeOptionTranscriptLocator(
      transcriptLocator,
      serializer,
    );
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandCaptureEvent &&
        ingestionKey == other.ingestionKey &&
        source == other.source &&
        occurredAtMs == other.occurredAtMs &&
        recordedAtMs == other.recordedAtMs &&
        text == other.text &&
        application == other.application &&
        windowTitle == other.windowTitle &&
        transcriptLocator == other.transcriptLocator;
  }

  @override
  int get hashCode => Object.hash(
    ingestionKey,
    source,
    occurredAtMs,
    recordedAtMs,
    text,
    application,
    windowTitle,
    transcriptLocator,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'ingestionKey: $ingestionKey, '
          'source: $source, '
          'occurredAtMs: $occurredAtMs, '
          'recordedAtMs: $recordedAtMs, '
          'text: [REDACTED], '
          'application: [REDACTED], '
          'windowTitle: [REDACTED], '
          'transcriptLocator: $transcriptLocator'
          ')';
      return true;
    }());

    return fullString ?? 'CommandCaptureEvent';
  }
}

@immutable
class CommandSearchMemory extends Command {
  const CommandSearchMemory({required this.query, required this.limit})
    : super();

  static CommandSearchMemory load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandSearchMemory(
      query: deserializer.deserializeString(),
      limit: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String query;
  final int limit;

  CommandSearchMemory copyWith({String? query, int? limit}) {
    return CommandSearchMemory(
      query: query ?? this.query,
      limit: limit ?? this.limit,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(9);
    serializer.serializeString(query);
    serializer.serializeUint32(limit);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandSearchMemory &&
        query == other.query &&
        limit == other.limit;
  }

  @override
  int get hashCode => Object.hash(query, limit);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'query: $query, '
          'limit: $limit'
          ')';
      return true;
    }());

    return fullString ?? 'CommandSearchMemory';
  }
}

@immutable
class CommandCorrectMemory extends Command {
  const CommandCorrectMemory({
    required this.claimId,
    required this.text,
    required this.value,
    required this.occurredAtMs,
    required this.recordedAtMs,
  }) : super();

  static CommandCorrectMemory load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandCorrectMemory(
      claimId: deserializer.deserializeString(),
      text: deserializer.deserializeString(),
      value: deserializer.deserializeString(),
      occurredAtMs: deserializer.deserializeInt64(),
      recordedAtMs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String claimId;
  final String text;
  final String value;
  final int occurredAtMs;
  final int recordedAtMs;

  CommandCorrectMemory copyWith({
    String? claimId,
    String? text,
    String? value,
    int? occurredAtMs,
    int? recordedAtMs,
  }) {
    return CommandCorrectMemory(
      claimId: claimId ?? this.claimId,
      text: text ?? this.text,
      value: value ?? this.value,
      occurredAtMs: occurredAtMs ?? this.occurredAtMs,
      recordedAtMs: recordedAtMs ?? this.recordedAtMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(10);
    serializer.serializeString(claimId);
    serializer.serializeString(text);
    serializer.serializeString(value);
    serializer.serializeInt64(occurredAtMs);
    serializer.serializeInt64(recordedAtMs);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandCorrectMemory &&
        claimId == other.claimId &&
        text == other.text &&
        value == other.value &&
        occurredAtMs == other.occurredAtMs &&
        recordedAtMs == other.recordedAtMs;
  }

  @override
  int get hashCode =>
      Object.hash(claimId, text, value, occurredAtMs, recordedAtMs);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'claimId: $claimId, '
          'text: [REDACTED], '
          'value: [REDACTED], '
          'occurredAtMs: $occurredAtMs, '
          'recordedAtMs: $recordedAtMs'
          ')';
      return true;
    }());

    return fullString ?? 'CommandCorrectMemory';
  }
}

@immutable
class CommandDeleteMemorySource extends Command {
  const CommandDeleteMemorySource({
    required this.sourceId,
    required this.deletedAtMs,
  }) : super();

  static CommandDeleteMemorySource load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandDeleteMemorySource(
      sourceId: deserializer.deserializeString(),
      deletedAtMs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String sourceId;
  final int deletedAtMs;

  CommandDeleteMemorySource copyWith({String? sourceId, int? deletedAtMs}) {
    return CommandDeleteMemorySource(
      sourceId: sourceId ?? this.sourceId,
      deletedAtMs: deletedAtMs ?? this.deletedAtMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(11);
    serializer.serializeString(sourceId);
    serializer.serializeInt64(deletedAtMs);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandDeleteMemorySource &&
        sourceId == other.sourceId &&
        deletedAtMs == other.deletedAtMs;
  }

  @override
  int get hashCode => Object.hash(sourceId, deletedAtMs);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'sourceId: $sourceId, '
          'deletedAtMs: $deletedAtMs'
          ')';
      return true;
    }());

    return fullString ?? 'CommandDeleteMemorySource';
  }
}

@immutable
class CommandApprovalDecision extends Command {
  const CommandApprovalDecision({
    required this.proposalId,
    required this.decision,
  }) : super();

  static CommandApprovalDecision load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandApprovalDecision(
      proposalId: deserializer.deserializeString(),
      decision: ApprovalDecisionExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String proposalId;
  final ApprovalDecision decision;

  CommandApprovalDecision copyWith({
    String? proposalId,
    ApprovalDecision? decision,
  }) {
    return CommandApprovalDecision(
      proposalId: proposalId ?? this.proposalId,
      decision: decision ?? this.decision,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(12);
    serializer.serializeString(proposalId);
    decision.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandApprovalDecision &&
        proposalId == other.proposalId &&
        decision == other.decision;
  }

  @override
  int get hashCode => Object.hash(proposalId, decision);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'proposalId: $proposalId, '
          'decision: $decision'
          ')';
      return true;
    }());

    return fullString ?? 'CommandApprovalDecision';
  }
}

@immutable
class CommandDeviceState extends Command {
  const CommandDeviceState({
    required this.deviceId,
    required this.connected,
    this.batteryPercent,
    this.firmwareVersion,
  }) : super();

  static CommandDeviceState load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandDeviceState(
      deviceId: deserializer.deserializeString(),
      connected: deserializer.deserializeBool(),
      batteryPercent: TraitHelpers.deserializeOptionU8(deserializer),
      firmwareVersion: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;
  final bool connected;
  final int? batteryPercent;
  final String? firmwareVersion;

  CommandDeviceState copyWith({
    String? deviceId,
    bool? connected,
    int? Function()? batteryPercent,
    String? Function()? firmwareVersion,
  }) {
    return CommandDeviceState(
      deviceId: deviceId ?? this.deviceId,
      connected: connected ?? this.connected,
      batteryPercent: batteryPercent == null
          ? this.batteryPercent
          : batteryPercent(),
      firmwareVersion: firmwareVersion == null
          ? this.firmwareVersion
          : firmwareVersion(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(13);
    serializer.serializeString(deviceId);
    serializer.serializeBool(connected);
    TraitHelpers.serializeOptionU8(batteryPercent, serializer);
    TraitHelpers.serializeOptionStr(firmwareVersion, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandDeviceState &&
        deviceId == other.deviceId &&
        connected == other.connected &&
        batteryPercent == other.batteryPercent &&
        firmwareVersion == other.firmwareVersion;
  }

  @override
  int get hashCode =>
      Object.hash(deviceId, connected, batteryPercent, firmwareVersion);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'deviceId: $deviceId, '
          'connected: $connected, '
          'batteryPercent: $batteryPercent, '
          'firmwareVersion: $firmwareVersion'
          ')';
      return true;
    }());

    return fullString ?? 'CommandDeviceState';
  }
}

@immutable
class CommandCancel extends Command {
  const CommandCancel() : super();

  static CommandCancel load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandCancel();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(14);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandCancel;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          ')';
      return true;
    }());

    return fullString ?? 'CommandCancel';
  }
}
