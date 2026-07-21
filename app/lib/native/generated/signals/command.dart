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
        return CommandCaptureEvent.load(deserializer);
      case 3:
        return CommandSearchMemory.load(deserializer);
      case 4:
        return CommandApprovalDecision.load(deserializer);
      case 5:
        return CommandDeviceState.load(deserializer);
      case 6:
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
          'text: $text, '
          'conversationId: $conversationId'
          ')';
      return true;
    }());

    return fullString ?? 'CommandSendMessage';
  }
}

@immutable
class CommandCaptureEvent extends Command {
  const CommandCaptureEvent({
    required this.source,
    required this.occurredAtMs,
    this.text,
    this.application,
    this.windowTitle,
  }) : super();

  static CommandCaptureEvent load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CommandCaptureEvent(
      source: CaptureSourceExtension.deserialize(deserializer),
      occurredAtMs: deserializer.deserializeInt64(),
      text: TraitHelpers.deserializeOptionStr(deserializer),
      application: TraitHelpers.deserializeOptionStr(deserializer),
      windowTitle: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final CaptureSource source;
  final int occurredAtMs;
  final String? text;
  final String? application;
  final String? windowTitle;

  CommandCaptureEvent copyWith({
    CaptureSource? source,
    int? occurredAtMs,
    String? Function()? text,
    String? Function()? application,
    String? Function()? windowTitle,
  }) {
    return CommandCaptureEvent(
      source: source ?? this.source,
      occurredAtMs: occurredAtMs ?? this.occurredAtMs,
      text: text == null ? this.text : text(),
      application: application == null ? this.application : application(),
      windowTitle: windowTitle == null ? this.windowTitle : windowTitle(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    source.serialize(serializer);
    serializer.serializeInt64(occurredAtMs);
    TraitHelpers.serializeOptionStr(text, serializer);
    TraitHelpers.serializeOptionStr(application, serializer);
    TraitHelpers.serializeOptionStr(windowTitle, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CommandCaptureEvent &&
        source == other.source &&
        occurredAtMs == other.occurredAtMs &&
        text == other.text &&
        application == other.application &&
        windowTitle == other.windowTitle;
  }

  @override
  int get hashCode =>
      Object.hash(source, occurredAtMs, text, application, windowTitle);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'source: $source, '
          'occurredAtMs: $occurredAtMs, '
          'text: $text, '
          'application: $application, '
          'windowTitle: $windowTitle'
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
    serializer.serializeVariantIndex(3);
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
    serializer.serializeVariantIndex(4);
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
    serializer.serializeVariantIndex(5);
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
    serializer.serializeVariantIndex(6);
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
