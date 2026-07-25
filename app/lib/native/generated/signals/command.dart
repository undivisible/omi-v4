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
        return CommandStartLiveVoice.load(deserializer);
      case 8:
        return CommandStopLiveVoice.load(deserializer);
      case 9:
        return CommandCaptureEvent.load(deserializer);
      case 10:
        return CommandSearchMemory.load(deserializer);
      case 11:
        return CommandExportMemory.load(deserializer);
      case 12:
        return CommandApplyMemory.load(deserializer);
      case 13:
        return CommandListMemoryItems.load(deserializer);
      case 14:
        return CommandCorrectMemory.load(deserializer);
      case 15:
        return CommandDeleteMemorySource.load(deserializer);
      case 16:
        return CommandScanOnboarding.load(deserializer);
      case 17:
        return CommandApprovalDecision.load(deserializer);
      case 18:
        return CommandDeviceState.load(deserializer);
      case 19:
        return CommandCancel.load(deserializer);
      case 20:
        return CommandStartMeeting.load(deserializer);
      case 21:
        return CommandStopMeeting.load(deserializer);
      case 22:
        return CommandJotMeetingNote.load(deserializer);
      case 23:
        return CommandProvideMeetingAuth.load(deserializer);
      case 24:
        return CommandSetSystemAudioCaptureMode.load(deserializer);
      case 25:
        return CommandComposeBrief.load(deserializer);
      case 26:
        return CommandJoinCall.load(deserializer);
      case 27:
        return CommandResolveDevAssistant.load(deserializer);
      case 28:
        return CommandUpdateLiveVoiceContext.load(deserializer);
      case 29:
        return CommandOpenCaptureWal.load(deserializer);
      case 30:
        return CommandConfigureCaptureUpload.load(deserializer);
      case 31:
        return CommandBeginCaptureSegment.load(deserializer);
      case 32:
        return CommandAppendCaptureAudio.load(deserializer);
      case 33:
        return CommandSealCaptureSegment.load(deserializer);
      case 34:
        return CommandDrainCaptureWal.load(deserializer);
      case 35:
        return CommandReadCaptureWalState.load(deserializer);
      case 36:
        return CommandCloseCaptureWal.load(deserializer);
      case 37:
        return CommandRecordCaptureGap.load(deserializer);
      case 38:
        return CommandRecordCaptureResume.load(deserializer);
      case 39:
        return CommandReadCaptureGaps.load(deserializer);
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
  const CommandSendMessage({
    required this.text,
    this.conversationId,
    this.memoryContext,
    this.origin,
  }) : super();

  static CommandSendMessage load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandSendMessage(
      text: deserializer.deserializeString(),
      conversationId: TraitHelpers.deserializeOptionStr(deserializer),
      memoryContext: TraitHelpers.deserializeOptionStr(deserializer),
      origin: TraitHelpers.deserializeOptionMessageOrigin(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String text;
  final String? conversationId;
  final String? memoryContext;
  final MessageOrigin? origin;

  CommandSendMessage copyWith({
    String? text,
    String? Function()? conversationId,
    String? Function()? memoryContext,
    MessageOrigin? Function()? origin,
  }) {
    return CommandSendMessage(
      text: text ?? this.text,
      conversationId: conversationId == null
          ? this.conversationId
          : conversationId(),
      memoryContext: memoryContext == null
          ? this.memoryContext
          : memoryContext(),
      origin: origin == null ? this.origin : origin(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(text);
    TraitHelpers.serializeOptionStr(conversationId, serializer);
    TraitHelpers.serializeOptionStr(memoryContext, serializer);
    TraitHelpers.serializeOptionMessageOrigin(origin, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandSendMessage &&
        text == other.text &&
        conversationId == other.conversationId &&
        memoryContext == other.memoryContext &&
        origin == other.origin;
  }

  @override
  int get hashCode => Object.hash(text, conversationId, memoryContext, origin);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'text: [REDACTED], '
          'conversationId: $conversationId, '
          'memoryContext: [REDACTED], '
          'origin: $origin'
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
class CommandStartLiveVoice extends Command {
  const CommandStartLiveVoice({
    required this.liveStreamId,
    required this.ephemeralToken,
    required this.model,
    this.resumptionHandle,
    this.sessionContext,
  }) : super();

  static CommandStartLiveVoice load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandStartLiveVoice(
      liveStreamId: deserializer.deserializeString(),
      ephemeralToken: deserializer.deserializeString(),
      model: deserializer.deserializeString(),
      resumptionHandle: TraitHelpers.deserializeOptionStr(deserializer),
      sessionContext: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String liveStreamId;
  final String ephemeralToken;
  final String model;
  final String? resumptionHandle;
  final String? sessionContext;

  CommandStartLiveVoice copyWith({
    String? liveStreamId,
    String? ephemeralToken,
    String? model,
    String? Function()? resumptionHandle,
    String? Function()? sessionContext,
  }) {
    return CommandStartLiveVoice(
      liveStreamId: liveStreamId ?? this.liveStreamId,
      ephemeralToken: ephemeralToken ?? this.ephemeralToken,
      model: model ?? this.model,
      resumptionHandle: resumptionHandle == null
          ? this.resumptionHandle
          : resumptionHandle(),
      sessionContext: sessionContext == null
          ? this.sessionContext
          : sessionContext(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(7);
    serializer.serializeString(liveStreamId);
    serializer.serializeString(ephemeralToken);
    serializer.serializeString(model);
    TraitHelpers.serializeOptionStr(resumptionHandle, serializer);
    TraitHelpers.serializeOptionStr(sessionContext, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandStartLiveVoice &&
        liveStreamId == other.liveStreamId &&
        ephemeralToken == other.ephemeralToken &&
        model == other.model &&
        resumptionHandle == other.resumptionHandle &&
        sessionContext == other.sessionContext;
  }

  @override
  int get hashCode => Object.hash(
    liveStreamId,
    ephemeralToken,
    model,
    resumptionHandle,
    sessionContext,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'liveStreamId: $liveStreamId, '
          'ephemeralToken: [REDACTED], '
          'model: $model, '
          'resumptionHandle: $resumptionHandle, '
          'sessionContext: $sessionContext'
          ')';
      return true;
    }());

    return fullString ?? 'CommandStartLiveVoice';
  }
}

@immutable
class CommandStopLiveVoice extends Command {
  const CommandStopLiveVoice({required this.liveStreamId}) : super();

  static CommandStopLiveVoice load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandStopLiveVoice(
      liveStreamId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String liveStreamId;

  CommandStopLiveVoice copyWith({String? liveStreamId}) {
    return CommandStopLiveVoice(
      liveStreamId: liveStreamId ?? this.liveStreamId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(8);
    serializer.serializeString(liveStreamId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandStopLiveVoice && liveStreamId == other.liveStreamId;
  }

  @override
  int get hashCode => liveStreamId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'liveStreamId: $liveStreamId'
          ')';
      return true;
    }());

    return fullString ?? 'CommandStopLiveVoice';
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
    serializer.serializeVariantIndex(9);
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
  const CommandSearchMemory({
    required this.query,
    required this.limit,
    this.asOfValidAtMs,
    this.asOfRecordedAtMs,
  }) : super();

  static CommandSearchMemory load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandSearchMemory(
      query: deserializer.deserializeString(),
      limit: deserializer.deserializeUint32(),
      asOfValidAtMs: TraitHelpers.deserializeOptionI64(deserializer),
      asOfRecordedAtMs: TraitHelpers.deserializeOptionI64(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String query;
  final int limit;
  final int? asOfValidAtMs;
  final int? asOfRecordedAtMs;

  CommandSearchMemory copyWith({
    String? query,
    int? limit,
    int? Function()? asOfValidAtMs,
    int? Function()? asOfRecordedAtMs,
  }) {
    return CommandSearchMemory(
      query: query ?? this.query,
      limit: limit ?? this.limit,
      asOfValidAtMs: asOfValidAtMs == null
          ? this.asOfValidAtMs
          : asOfValidAtMs(),
      asOfRecordedAtMs: asOfRecordedAtMs == null
          ? this.asOfRecordedAtMs
          : asOfRecordedAtMs(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(10);
    serializer.serializeString(query);
    serializer.serializeUint32(limit);
    TraitHelpers.serializeOptionI64(asOfValidAtMs, serializer);
    TraitHelpers.serializeOptionI64(asOfRecordedAtMs, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandSearchMemory &&
        query == other.query &&
        limit == other.limit &&
        asOfValidAtMs == other.asOfValidAtMs &&
        asOfRecordedAtMs == other.asOfRecordedAtMs;
  }

  @override
  int get hashCode =>
      Object.hash(query, limit, asOfValidAtMs, asOfRecordedAtMs);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'query: $query, '
          'limit: $limit, '
          'asOfValidAtMs: $asOfValidAtMs, '
          'asOfRecordedAtMs: $asOfRecordedAtMs'
          ')';
      return true;
    }());

    return fullString ?? 'CommandSearchMemory';
  }
}

@immutable
class CommandExportMemory extends Command {
  const CommandExportMemory({
    required this.afterCommit,
    required this.afterEventIndex,
    this.highWaterMark,
    required this.limit,
  }) : super();

  static CommandExportMemory load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandExportMemory(
      afterCommit: deserializer.deserializeInt64(),
      afterEventIndex: deserializer.deserializeInt64(),
      highWaterMark: TraitHelpers.deserializeOptionI64(deserializer),
      limit: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final int afterCommit;
  final int afterEventIndex;
  final int? highWaterMark;
  final int limit;

  CommandExportMemory copyWith({
    int? afterCommit,
    int? afterEventIndex,
    int? Function()? highWaterMark,
    int? limit,
  }) {
    return CommandExportMemory(
      afterCommit: afterCommit ?? this.afterCommit,
      afterEventIndex: afterEventIndex ?? this.afterEventIndex,
      highWaterMark: highWaterMark == null
          ? this.highWaterMark
          : highWaterMark(),
      limit: limit ?? this.limit,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(11);
    serializer.serializeInt64(afterCommit);
    serializer.serializeInt64(afterEventIndex);
    TraitHelpers.serializeOptionI64(highWaterMark, serializer);
    serializer.serializeUint32(limit);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandExportMemory &&
        afterCommit == other.afterCommit &&
        afterEventIndex == other.afterEventIndex &&
        highWaterMark == other.highWaterMark &&
        limit == other.limit;
  }

  @override
  int get hashCode =>
      Object.hash(afterCommit, afterEventIndex, highWaterMark, limit);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'afterCommit: $afterCommit, '
          'afterEventIndex: $afterEventIndex, '
          'highWaterMark: $highWaterMark, '
          'limit: $limit'
          ')';
      return true;
    }());

    return fullString ?? 'CommandExportMemory';
  }
}

@immutable
class CommandApplyMemory extends Command {
  const CommandApplyMemory({required this.commits}) : super();

  static CommandApplyMemory load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandApplyMemory(
      commits: TraitHelpers.deserializeVectorMemoryApplyCommit(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<MemoryApplyCommit> commits;

  CommandApplyMemory copyWith({List<MemoryApplyCommit>? commits}) {
    return CommandApplyMemory(commits: commits ?? this.commits);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(12);
    TraitHelpers.serializeVectorMemoryApplyCommit(commits, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandApplyMemory && listEquals(commits, other.commits);
  }

  @override
  int get hashCode => commits.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'commits: $commits'
          ')';
      return true;
    }());

    return fullString ?? 'CommandApplyMemory';
  }
}

@immutable
class CommandListMemoryItems extends Command {
  const CommandListMemoryItems({required this.limit}) : super();

  static CommandListMemoryItems load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandListMemoryItems(
      limit: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final int limit;

  CommandListMemoryItems copyWith({int? limit}) {
    return CommandListMemoryItems(limit: limit ?? this.limit);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(13);
    serializer.serializeUint32(limit);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandListMemoryItems && limit == other.limit;
  }

  @override
  int get hashCode => limit.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'limit: $limit'
          ')';
      return true;
    }());

    return fullString ?? 'CommandListMemoryItems';
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
    serializer.serializeVariantIndex(14);
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
    serializer.serializeVariantIndex(15);
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
class CommandScanOnboarding extends Command {
  const CommandScanOnboarding({
    required this.roots,
    required this.includeAppleNotes,
    required this.includeAppleMail,
    required this.recordedAtMs,
  }) : super();

  static CommandScanOnboarding load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandScanOnboarding(
      roots: TraitHelpers.deserializeVectorStr(deserializer),
      includeAppleNotes: deserializer.deserializeBool(),
      includeAppleMail: deserializer.deserializeBool(),
      recordedAtMs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<String> roots;
  final bool includeAppleNotes;
  final bool includeAppleMail;
  final int recordedAtMs;

  CommandScanOnboarding copyWith({
    List<String>? roots,
    bool? includeAppleNotes,
    bool? includeAppleMail,
    int? recordedAtMs,
  }) {
    return CommandScanOnboarding(
      roots: roots ?? this.roots,
      includeAppleNotes: includeAppleNotes ?? this.includeAppleNotes,
      includeAppleMail: includeAppleMail ?? this.includeAppleMail,
      recordedAtMs: recordedAtMs ?? this.recordedAtMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(16);
    TraitHelpers.serializeVectorStr(roots, serializer);
    serializer.serializeBool(includeAppleNotes);
    serializer.serializeBool(includeAppleMail);
    serializer.serializeInt64(recordedAtMs);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandScanOnboarding &&
        listEquals(roots, other.roots) &&
        includeAppleNotes == other.includeAppleNotes &&
        includeAppleMail == other.includeAppleMail &&
        recordedAtMs == other.recordedAtMs;
  }

  @override
  int get hashCode =>
      Object.hash(roots, includeAppleNotes, includeAppleMail, recordedAtMs);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'roots: $roots, '
          'includeAppleNotes: $includeAppleNotes, '
          'includeAppleMail: $includeAppleMail, '
          'recordedAtMs: $recordedAtMs'
          ')';
      return true;
    }());

    return fullString ?? 'CommandScanOnboarding';
  }
}

@immutable
class CommandApprovalDecision extends Command {
  const CommandApprovalDecision({
    required this.proposalId,
    required this.decision,
    this.authorityReceipt,
  }) : super();

  static CommandApprovalDecision load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandApprovalDecision(
      proposalId: deserializer.deserializeString(),
      decision: ApprovalDecisionExtension.deserialize(deserializer),
      authorityReceipt:
          TraitHelpers.deserializeOptionComputerUseAuthorityReceipt(
            deserializer,
          ),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String proposalId;
  final ApprovalDecision decision;
  final ComputerUseAuthorityReceipt? authorityReceipt;

  CommandApprovalDecision copyWith({
    String? proposalId,
    ApprovalDecision? decision,
    ComputerUseAuthorityReceipt? Function()? authorityReceipt,
  }) {
    return CommandApprovalDecision(
      proposalId: proposalId ?? this.proposalId,
      decision: decision ?? this.decision,
      authorityReceipt: authorityReceipt == null
          ? this.authorityReceipt
          : authorityReceipt(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(17);
    serializer.serializeString(proposalId);
    decision.serialize(serializer);
    TraitHelpers.serializeOptionComputerUseAuthorityReceipt(
      authorityReceipt,
      serializer,
    );
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandApprovalDecision &&
        proposalId == other.proposalId &&
        decision == other.decision &&
        authorityReceipt == other.authorityReceipt;
  }

  @override
  int get hashCode => Object.hash(proposalId, decision, authorityReceipt);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'proposalId: $proposalId, '
          'decision: $decision, '
          'authorityReceipt: $authorityReceipt'
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
    serializer.serializeVariantIndex(18);
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
    serializer.serializeVariantIndex(19);
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

@immutable
class CommandStartMeeting extends Command {
  const CommandStartMeeting({this.title}) : super();

  static CommandStartMeeting load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandStartMeeting(
      title: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String? title;

  CommandStartMeeting copyWith({String? Function()? title}) {
    return CommandStartMeeting(title: title == null ? this.title : title());
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(20);
    TraitHelpers.serializeOptionStr(title, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandStartMeeting && title == other.title;
  }

  @override
  int get hashCode => title.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'title: $title'
          ')';
      return true;
    }());

    return fullString ?? 'CommandStartMeeting';
  }
}

@immutable
class CommandStopMeeting extends Command {
  const CommandStopMeeting() : super();

  static CommandStopMeeting load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandStopMeeting();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(21);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandStopMeeting;
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

    return fullString ?? 'CommandStopMeeting';
  }
}

@immutable
class CommandJotMeetingNote extends Command {
  const CommandJotMeetingNote({required this.text}) : super();

  static CommandJotMeetingNote load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandJotMeetingNote(
      text: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String text;

  CommandJotMeetingNote copyWith({String? text}) {
    return CommandJotMeetingNote(text: text ?? this.text);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(22);
    serializer.serializeString(text);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandJotMeetingNote && text == other.text;
  }

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'text: $text'
          ')';
      return true;
    }());

    return fullString ?? 'CommandJotMeetingNote';
  }
}

@immutable
class CommandProvideMeetingAuth extends Command {
  const CommandProvideMeetingAuth({
    required this.auth,
    this.trustedWorkerOrigin,
  }) : super();

  static CommandProvideMeetingAuth load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandProvideMeetingAuth(
      auth: TranscriptionAuth.deserialize(deserializer),
      trustedWorkerOrigin: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final TranscriptionAuth auth;
  final String? trustedWorkerOrigin;

  CommandProvideMeetingAuth copyWith({
    TranscriptionAuth? auth,
    String? Function()? trustedWorkerOrigin,
  }) {
    return CommandProvideMeetingAuth(
      auth: auth ?? this.auth,
      trustedWorkerOrigin: trustedWorkerOrigin == null
          ? this.trustedWorkerOrigin
          : trustedWorkerOrigin(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(23);
    auth.serialize(serializer);
    TraitHelpers.serializeOptionStr(trustedWorkerOrigin, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandProvideMeetingAuth &&
        auth == other.auth &&
        trustedWorkerOrigin == other.trustedWorkerOrigin;
  }

  @override
  int get hashCode => Object.hash(auth, trustedWorkerOrigin);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'auth: $auth, '
          'trustedWorkerOrigin: $trustedWorkerOrigin'
          ')';
      return true;
    }());

    return fullString ?? 'CommandProvideMeetingAuth';
  }
}

@immutable
class CommandSetSystemAudioCaptureMode extends Command {
  const CommandSetSystemAudioCaptureMode({required this.mode}) : super();

  static CommandSetSystemAudioCaptureMode load(
    BinaryDeserializer deserializer,
  ) {
    deserializer.increaseContainerDepth();
    final instance = CommandSetSystemAudioCaptureMode(
      mode: SystemAudioCaptureModeExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final SystemAudioCaptureMode mode;

  CommandSetSystemAudioCaptureMode copyWith({SystemAudioCaptureMode? mode}) {
    return CommandSetSystemAudioCaptureMode(mode: mode ?? this.mode);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(24);
    mode.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandSetSystemAudioCaptureMode && mode == other.mode;
  }

  @override
  int get hashCode => mode.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'mode: $mode'
          ')';
      return true;
    }());

    return fullString ?? 'CommandSetSystemAudioCaptureMode';
  }
}

@immutable
class CommandComposeBrief extends Command {
  const CommandComposeBrief({required this.nowLocal, required this.items})
    : super();

  static CommandComposeBrief load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandComposeBrief(
      nowLocal: deserializer.deserializeString(),
      items: TraitHelpers.deserializeVectorBriefItem(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String nowLocal;
  final List<BriefItem> items;

  CommandComposeBrief copyWith({String? nowLocal, List<BriefItem>? items}) {
    return CommandComposeBrief(
      nowLocal: nowLocal ?? this.nowLocal,
      items: items ?? this.items,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(25);
    serializer.serializeString(nowLocal);
    TraitHelpers.serializeVectorBriefItem(items, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandComposeBrief &&
        nowLocal == other.nowLocal &&
        listEquals(items, other.items);
  }

  @override
  int get hashCode => Object.hash(nowLocal, items);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'nowLocal: $nowLocal, '
          'items: $items'
          ')';
      return true;
    }());

    return fullString ?? 'CommandComposeBrief';
  }
}

@immutable
class CommandJoinCall extends Command {
  const CommandJoinCall({
    required this.link,
    this.displayName,
    required this.video,
    required this.ephemeralToken,
    required this.model,
  }) : super();

  static CommandJoinCall load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandJoinCall(
      link: deserializer.deserializeString(),
      displayName: TraitHelpers.deserializeOptionStr(deserializer),
      video: deserializer.deserializeBool(),
      ephemeralToken: deserializer.deserializeString(),
      model: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String link;
  final String? displayName;
  final bool video;
  final String ephemeralToken;
  final String model;

  CommandJoinCall copyWith({
    String? link,
    String? Function()? displayName,
    bool? video,
    String? ephemeralToken,
    String? model,
  }) {
    return CommandJoinCall(
      link: link ?? this.link,
      displayName: displayName == null ? this.displayName : displayName(),
      video: video ?? this.video,
      ephemeralToken: ephemeralToken ?? this.ephemeralToken,
      model: model ?? this.model,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(26);
    serializer.serializeString(link);
    TraitHelpers.serializeOptionStr(displayName, serializer);
    serializer.serializeBool(video);
    serializer.serializeString(ephemeralToken);
    serializer.serializeString(model);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandJoinCall &&
        link == other.link &&
        displayName == other.displayName &&
        video == other.video &&
        ephemeralToken == other.ephemeralToken &&
        model == other.model;
  }

  @override
  int get hashCode =>
      Object.hash(link, displayName, video, ephemeralToken, model);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'link: $link, '
          'displayName: $displayName, '
          'video: $video, '
          'ephemeralToken: $ephemeralToken, '
          'model: $model'
          ')';
      return true;
    }());

    return fullString ?? 'CommandJoinCall';
  }
}

@immutable
class CommandResolveDevAssistant extends Command {
  const CommandResolveDevAssistant() : super();

  static CommandResolveDevAssistant load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandResolveDevAssistant();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(27);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandResolveDevAssistant;
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

    return fullString ?? 'CommandResolveDevAssistant';
  }
}

@immutable
class CommandUpdateLiveVoiceContext extends Command {
  const CommandUpdateLiveVoiceContext({
    required this.liveStreamId,
    required this.sessionContext,
  }) : super();

  static CommandUpdateLiveVoiceContext load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandUpdateLiveVoiceContext(
      liveStreamId: deserializer.deserializeString(),
      sessionContext: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String liveStreamId;
  final String sessionContext;

  CommandUpdateLiveVoiceContext copyWith({
    String? liveStreamId,
    String? sessionContext,
  }) {
    return CommandUpdateLiveVoiceContext(
      liveStreamId: liveStreamId ?? this.liveStreamId,
      sessionContext: sessionContext ?? this.sessionContext,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(28);
    serializer.serializeString(liveStreamId);
    serializer.serializeString(sessionContext);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandUpdateLiveVoiceContext &&
        liveStreamId == other.liveStreamId &&
        sessionContext == other.sessionContext;
  }

  @override
  int get hashCode => Object.hash(liveStreamId, sessionContext);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'liveStreamId: $liveStreamId, '
          'sessionContext: $sessionContext'
          ')';
      return true;
    }());

    return fullString ?? 'CommandUpdateLiveVoiceContext';
  }
}

@immutable
class CommandOpenCaptureWal extends Command {
  const CommandOpenCaptureWal({
    required this.directory,
    this.maxBytes,
    this.maxAgeMs,
    this.maxSegmentBytes,
  }) : super();

  static CommandOpenCaptureWal load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandOpenCaptureWal(
      directory: deserializer.deserializeString(),
      maxBytes: TraitHelpers.deserializeOptionU64(deserializer),
      maxAgeMs: TraitHelpers.deserializeOptionI64(deserializer),
      maxSegmentBytes: TraitHelpers.deserializeOptionU64(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String directory;
  final Uint64? maxBytes;
  final int? maxAgeMs;
  final Uint64? maxSegmentBytes;

  CommandOpenCaptureWal copyWith({
    String? directory,
    Uint64? Function()? maxBytes,
    int? Function()? maxAgeMs,
    Uint64? Function()? maxSegmentBytes,
  }) {
    return CommandOpenCaptureWal(
      directory: directory ?? this.directory,
      maxBytes: maxBytes == null ? this.maxBytes : maxBytes(),
      maxAgeMs: maxAgeMs == null ? this.maxAgeMs : maxAgeMs(),
      maxSegmentBytes: maxSegmentBytes == null
          ? this.maxSegmentBytes
          : maxSegmentBytes(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(29);
    serializer.serializeString(directory);
    TraitHelpers.serializeOptionU64(maxBytes, serializer);
    TraitHelpers.serializeOptionI64(maxAgeMs, serializer);
    TraitHelpers.serializeOptionU64(maxSegmentBytes, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandOpenCaptureWal &&
        directory == other.directory &&
        maxBytes == other.maxBytes &&
        maxAgeMs == other.maxAgeMs &&
        maxSegmentBytes == other.maxSegmentBytes;
  }

  @override
  int get hashCode =>
      Object.hash(directory, maxBytes, maxAgeMs, maxSegmentBytes);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'directory: $directory, '
          'maxBytes: $maxBytes, '
          'maxAgeMs: $maxAgeMs, '
          'maxSegmentBytes: $maxSegmentBytes'
          ')';
      return true;
    }());

    return fullString ?? 'CommandOpenCaptureWal';
  }
}

@immutable
class CommandConfigureCaptureUpload extends Command {
  const CommandConfigureCaptureUpload({this.endpoint, this.firebaseToken})
    : super();

  static CommandConfigureCaptureUpload load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandConfigureCaptureUpload(
      endpoint: TraitHelpers.deserializeOptionStr(deserializer),
      firebaseToken: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String? endpoint;
  final String? firebaseToken;

  CommandConfigureCaptureUpload copyWith({
    String? Function()? endpoint,
    String? Function()? firebaseToken,
  }) {
    return CommandConfigureCaptureUpload(
      endpoint: endpoint == null ? this.endpoint : endpoint(),
      firebaseToken: firebaseToken == null
          ? this.firebaseToken
          : firebaseToken(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(30);
    TraitHelpers.serializeOptionStr(endpoint, serializer);
    TraitHelpers.serializeOptionStr(firebaseToken, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandConfigureCaptureUpload &&
        endpoint == other.endpoint &&
        firebaseToken == other.firebaseToken;
  }

  @override
  int get hashCode => Object.hash(endpoint, firebaseToken);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'endpoint: $endpoint, '
          'firebaseToken: [REDACTED]'
          ')';
      return true;
    }());

    return fullString ?? 'CommandConfigureCaptureUpload';
  }
}

@immutable
class CommandBeginCaptureSegment extends Command {
  const CommandBeginCaptureSegment({
    required this.deviceId,
    required this.audioStreamId,
    required this.encoding,
    required this.sampleRateHz,
    required this.channels,
    required this.gapBefore,
  }) : super();

  static CommandBeginCaptureSegment load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandBeginCaptureSegment(
      deviceId: deserializer.deserializeString(),
      audioStreamId: deserializer.deserializeString(),
      encoding: AudioEncodingExtension.deserialize(deserializer),
      sampleRateHz: deserializer.deserializeUint32(),
      channels: deserializer.deserializeUint8(),
      gapBefore: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;
  final String audioStreamId;
  final AudioEncoding encoding;
  final int sampleRateHz;
  final int channels;
  final bool gapBefore;

  CommandBeginCaptureSegment copyWith({
    String? deviceId,
    String? audioStreamId,
    AudioEncoding? encoding,
    int? sampleRateHz,
    int? channels,
    bool? gapBefore,
  }) {
    return CommandBeginCaptureSegment(
      deviceId: deviceId ?? this.deviceId,
      audioStreamId: audioStreamId ?? this.audioStreamId,
      encoding: encoding ?? this.encoding,
      sampleRateHz: sampleRateHz ?? this.sampleRateHz,
      channels: channels ?? this.channels,
      gapBefore: gapBefore ?? this.gapBefore,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(31);
    serializer.serializeString(deviceId);
    serializer.serializeString(audioStreamId);
    encoding.serialize(serializer);
    serializer.serializeUint32(sampleRateHz);
    serializer.serializeUint8(channels);
    serializer.serializeBool(gapBefore);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandBeginCaptureSegment &&
        deviceId == other.deviceId &&
        audioStreamId == other.audioStreamId &&
        encoding == other.encoding &&
        sampleRateHz == other.sampleRateHz &&
        channels == other.channels &&
        gapBefore == other.gapBefore;
  }

  @override
  int get hashCode => Object.hash(
    deviceId,
    audioStreamId,
    encoding,
    sampleRateHz,
    channels,
    gapBefore,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'deviceId: $deviceId, '
          'audioStreamId: $audioStreamId, '
          'encoding: $encoding, '
          'sampleRateHz: $sampleRateHz, '
          'channels: $channels, '
          'gapBefore: $gapBefore'
          ')';
      return true;
    }());

    return fullString ?? 'CommandBeginCaptureSegment';
  }
}

@immutable
class CommandAppendCaptureAudio extends Command {
  const CommandAppendCaptureAudio({required this.bytes}) : super();

  static CommandAppendCaptureAudio load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandAppendCaptureAudio(
      bytes: TraitHelpers.deserializeVectorU8(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<int> bytes;

  CommandAppendCaptureAudio copyWith({List<int>? bytes}) {
    return CommandAppendCaptureAudio(bytes: bytes ?? this.bytes);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(32);
    TraitHelpers.serializeVectorU8(bytes, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandAppendCaptureAudio && listEquals(bytes, other.bytes);
  }

  @override
  int get hashCode => bytes.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'bytes: [REDACTED]'
          ')';
      return true;
    }());

    return fullString ?? 'CommandAppendCaptureAudio';
  }
}

@immutable
class CommandSealCaptureSegment extends Command {
  const CommandSealCaptureSegment() : super();

  static CommandSealCaptureSegment load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandSealCaptureSegment();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(33);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandSealCaptureSegment;
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

    return fullString ?? 'CommandSealCaptureSegment';
  }
}

@immutable
class CommandDrainCaptureWal extends Command {
  const CommandDrainCaptureWal() : super();

  static CommandDrainCaptureWal load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandDrainCaptureWal();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(34);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandDrainCaptureWal;
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

    return fullString ?? 'CommandDrainCaptureWal';
  }
}

@immutable
class CommandReadCaptureWalState extends Command {
  const CommandReadCaptureWalState() : super();

  static CommandReadCaptureWalState load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandReadCaptureWalState();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(35);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandReadCaptureWalState;
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

    return fullString ?? 'CommandReadCaptureWalState';
  }
}

@immutable
class CommandCloseCaptureWal extends Command {
  const CommandCloseCaptureWal() : super();

  static CommandCloseCaptureWal load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandCloseCaptureWal();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(36);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandCloseCaptureWal;
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

    return fullString ?? 'CommandCloseCaptureWal';
  }
}

@immutable
class CommandRecordCaptureGap extends Command {
  const CommandRecordCaptureGap({
    required this.deviceId,
    required this.reason,
    required this.endedAtMs,
    required this.endedStreamId,
  }) : super();

  static CommandRecordCaptureGap load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandRecordCaptureGap(
      deviceId: deserializer.deserializeString(),
      reason: deserializer.deserializeString(),
      endedAtMs: deserializer.deserializeInt64(),
      endedStreamId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;
  final String reason;
  final int endedAtMs;
  final String endedStreamId;

  CommandRecordCaptureGap copyWith({
    String? deviceId,
    String? reason,
    int? endedAtMs,
    String? endedStreamId,
  }) {
    return CommandRecordCaptureGap(
      deviceId: deviceId ?? this.deviceId,
      reason: reason ?? this.reason,
      endedAtMs: endedAtMs ?? this.endedAtMs,
      endedStreamId: endedStreamId ?? this.endedStreamId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(37);
    serializer.serializeString(deviceId);
    serializer.serializeString(reason);
    serializer.serializeInt64(endedAtMs);
    serializer.serializeString(endedStreamId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandRecordCaptureGap &&
        deviceId == other.deviceId &&
        reason == other.reason &&
        endedAtMs == other.endedAtMs &&
        endedStreamId == other.endedStreamId;
  }

  @override
  int get hashCode => Object.hash(deviceId, reason, endedAtMs, endedStreamId);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'deviceId: $deviceId, '
          'reason: $reason, '
          'endedAtMs: $endedAtMs, '
          'endedStreamId: $endedStreamId'
          ')';
      return true;
    }());

    return fullString ?? 'CommandRecordCaptureGap';
  }
}

@immutable
class CommandRecordCaptureResume extends Command {
  const CommandRecordCaptureResume({
    required this.deviceId,
    required this.atMs,
    required this.streamId,
  }) : super();

  static CommandRecordCaptureResume load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandRecordCaptureResume(
      deviceId: deserializer.deserializeString(),
      atMs: deserializer.deserializeInt64(),
      streamId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;
  final int atMs;
  final String streamId;

  CommandRecordCaptureResume copyWith({
    String? deviceId,
    int? atMs,
    String? streamId,
  }) {
    return CommandRecordCaptureResume(
      deviceId: deviceId ?? this.deviceId,
      atMs: atMs ?? this.atMs,
      streamId: streamId ?? this.streamId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(38);
    serializer.serializeString(deviceId);
    serializer.serializeInt64(atMs);
    serializer.serializeString(streamId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandRecordCaptureResume &&
        deviceId == other.deviceId &&
        atMs == other.atMs &&
        streamId == other.streamId;
  }

  @override
  int get hashCode => Object.hash(deviceId, atMs, streamId);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'deviceId: $deviceId, '
          'atMs: $atMs, '
          'streamId: $streamId'
          ')';
      return true;
    }());

    return fullString ?? 'CommandRecordCaptureResume';
  }
}

@immutable
class CommandReadCaptureGaps extends Command {
  const CommandReadCaptureGaps() : super();

  static CommandReadCaptureGaps load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandReadCaptureGaps();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(39);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandReadCaptureGaps;
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

    return fullString ?? 'CommandReadCaptureGaps';
  }
}
