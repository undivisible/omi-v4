// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

abstract class NativeEvent {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream = _nativeEventStreamController.stream
      .asBroadcastStream();

  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<NativeEvent>? latestRustSignal = null;

  const NativeEvent();

  void serialize(BinarySerializer serializer);

  static NativeEvent deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return NativeEventTranscriptDelta.load(deserializer);
      case 1:
        return NativeEventTranscriptionStatus.load(deserializer);
      case 2:
        return NativeEventTranscriptionStopAcknowledged.load(deserializer);
      case 3:
        return NativeEventTranscriptGap.load(deserializer);
      case 4:
        return NativeEventAssistantDelta.load(deserializer);
      case 5:
        return NativeEventCurrentUpdate.load(deserializer);
      case 6:
        return NativeEventActionProposal.load(deserializer);
      case 7:
        return NativeEventApprovalExecutionAcknowledged.load(deserializer);
      case 8:
        return NativeEventToolProgress.load(deserializer);
      case 9:
        return NativeEventError.load(deserializer);
      case 10:
        return NativeEventRuntimeStatus.load(deserializer);
      case 11:
        return NativeEventMemoryCaptured.load(deserializer);
      case 12:
        return NativeEventMemorySearchResults.load(deserializer);
      case 13:
        return NativeEventMemoryCorrected.load(deserializer);
      case 14:
        return NativeEventMemorySourceDeleted.load(deserializer);
      case 15:
        return NativeEventMemoryExported.load(deserializer);
      case 16:
        return NativeEventMemoryItems.load(deserializer);
      default:
        throw Exception(
          'Unknown variant index for NativeEvent: ' + index.toString(),
        );
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static NativeEvent bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = NativeEvent.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

@immutable
class NativeEventTranscriptDelta extends NativeEvent {
  const NativeEventTranscriptDelta({required this.value}) : super();

  static NativeEventTranscriptDelta load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventTranscriptDelta(
      value: TranscriptDelta.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final TranscriptDelta value;

  NativeEventTranscriptDelta copyWith({TranscriptDelta? value}) {
    return NativeEventTranscriptDelta(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventTranscriptDelta && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventTranscriptDelta';
  }
}

@immutable
class NativeEventTranscriptionStatus extends NativeEvent {
  const NativeEventTranscriptionStatus({required this.value}) : super();

  static NativeEventTranscriptionStatus load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventTranscriptionStatus(
      value: TranscriptionStatus.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final TranscriptionStatus value;

  NativeEventTranscriptionStatus copyWith({TranscriptionStatus? value}) {
    return NativeEventTranscriptionStatus(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventTranscriptionStatus && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventTranscriptionStatus';
  }
}

@immutable
class NativeEventTranscriptionStopAcknowledged extends NativeEvent {
  const NativeEventTranscriptionStopAcknowledged({required this.value})
    : super();

  static NativeEventTranscriptionStopAcknowledged load(
    BinaryDeserializer deserializer,
  ) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventTranscriptionStopAcknowledged(
      value: TranscriptionStopAcknowledgement.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final TranscriptionStopAcknowledgement value;

  NativeEventTranscriptionStopAcknowledged copyWith({
    TranscriptionStopAcknowledgement? value,
  }) {
    return NativeEventTranscriptionStopAcknowledged(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventTranscriptionStopAcknowledged &&
        value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventTranscriptionStopAcknowledged';
  }
}

@immutable
class NativeEventTranscriptGap extends NativeEvent {
  const NativeEventTranscriptGap({required this.value}) : super();

  static NativeEventTranscriptGap load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventTranscriptGap(
      value: TranscriptGap.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final TranscriptGap value;

  NativeEventTranscriptGap copyWith({TranscriptGap? value}) {
    return NativeEventTranscriptGap(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventTranscriptGap && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventTranscriptGap';
  }
}

@immutable
class NativeEventAssistantDelta extends NativeEvent {
  const NativeEventAssistantDelta({required this.value}) : super();

  static NativeEventAssistantDelta load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventAssistantDelta(
      value: AssistantDelta.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final AssistantDelta value;

  NativeEventAssistantDelta copyWith({AssistantDelta? value}) {
    return NativeEventAssistantDelta(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventAssistantDelta && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventAssistantDelta';
  }
}

@immutable
class NativeEventCurrentUpdate extends NativeEvent {
  const NativeEventCurrentUpdate({required this.value}) : super();

  static NativeEventCurrentUpdate load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventCurrentUpdate(
      value: CurrentUpdate.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final CurrentUpdate value;

  NativeEventCurrentUpdate copyWith({CurrentUpdate? value}) {
    return NativeEventCurrentUpdate(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventCurrentUpdate && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventCurrentUpdate';
  }
}

@immutable
class NativeEventActionProposal extends NativeEvent {
  const NativeEventActionProposal({required this.value}) : super();

  static NativeEventActionProposal load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventActionProposal(
      value: ActionProposal.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final ActionProposal value;

  NativeEventActionProposal copyWith({ActionProposal? value}) {
    return NativeEventActionProposal(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(6);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventActionProposal && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventActionProposal';
  }
}

@immutable
class NativeEventApprovalExecutionAcknowledged extends NativeEvent {
  const NativeEventApprovalExecutionAcknowledged({required this.value})
    : super();

  static NativeEventApprovalExecutionAcknowledged load(
    BinaryDeserializer deserializer,
  ) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventApprovalExecutionAcknowledged(
      value: ApprovalExecutionAcknowledgement.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final ApprovalExecutionAcknowledgement value;

  NativeEventApprovalExecutionAcknowledged copyWith({
    ApprovalExecutionAcknowledgement? value,
  }) {
    return NativeEventApprovalExecutionAcknowledged(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(7);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventApprovalExecutionAcknowledged &&
        value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventApprovalExecutionAcknowledged';
  }
}

@immutable
class NativeEventToolProgress extends NativeEvent {
  const NativeEventToolProgress({required this.value}) : super();

  static NativeEventToolProgress load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventToolProgress(
      value: ToolProgress.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final ToolProgress value;

  NativeEventToolProgress copyWith({ToolProgress? value}) {
    return NativeEventToolProgress(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(8);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventToolProgress && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventToolProgress';
  }
}

@immutable
class NativeEventError extends NativeEvent {
  const NativeEventError({required this.value}) : super();

  static NativeEventError load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventError(
      value: NativeError.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final NativeError value;

  NativeEventError copyWith({NativeError? value}) {
    return NativeEventError(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(9);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventError && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventError';
  }
}

@immutable
class NativeEventRuntimeStatus extends NativeEvent {
  const NativeEventRuntimeStatus({required this.value}) : super();

  static NativeEventRuntimeStatus load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventRuntimeStatus(
      value: RuntimeStatus.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final RuntimeStatus value;

  NativeEventRuntimeStatus copyWith({RuntimeStatus? value}) {
    return NativeEventRuntimeStatus(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(10);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventRuntimeStatus && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventRuntimeStatus';
  }
}

@immutable
class NativeEventMemoryCaptured extends NativeEvent {
  const NativeEventMemoryCaptured({required this.value}) : super();

  static NativeEventMemoryCaptured load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventMemoryCaptured(
      value: MemoryCaptured.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final MemoryCaptured value;

  NativeEventMemoryCaptured copyWith({MemoryCaptured? value}) {
    return NativeEventMemoryCaptured(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(11);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventMemoryCaptured && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventMemoryCaptured';
  }
}

@immutable
class NativeEventMemorySearchResults extends NativeEvent {
  const NativeEventMemorySearchResults({required this.value}) : super();

  static NativeEventMemorySearchResults load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventMemorySearchResults(
      value: MemorySearchResults.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final MemorySearchResults value;

  NativeEventMemorySearchResults copyWith({MemorySearchResults? value}) {
    return NativeEventMemorySearchResults(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(12);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventMemorySearchResults && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventMemorySearchResults';
  }
}

@immutable
class NativeEventMemoryCorrected extends NativeEvent {
  const NativeEventMemoryCorrected({required this.value}) : super();

  static NativeEventMemoryCorrected load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventMemoryCorrected(
      value: MemoryCorrected.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final MemoryCorrected value;

  NativeEventMemoryCorrected copyWith({MemoryCorrected? value}) {
    return NativeEventMemoryCorrected(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(13);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventMemoryCorrected && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventMemoryCorrected';
  }
}

@immutable
class NativeEventMemorySourceDeleted extends NativeEvent {
  const NativeEventMemorySourceDeleted({required this.value}) : super();

  static NativeEventMemorySourceDeleted load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventMemorySourceDeleted(
      value: MemorySourceDeleted.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final MemorySourceDeleted value;

  NativeEventMemorySourceDeleted copyWith({MemorySourceDeleted? value}) {
    return NativeEventMemorySourceDeleted(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(14);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventMemorySourceDeleted && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventMemorySourceDeleted';
  }
}

@immutable
class NativeEventMemoryExported extends NativeEvent {
  const NativeEventMemoryExported({required this.value}) : super();

  static NativeEventMemoryExported load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventMemoryExported(
      value: MemoryExported.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final MemoryExported value;

  NativeEventMemoryExported copyWith({MemoryExported? value}) {
    return NativeEventMemoryExported(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(15);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventMemoryExported && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventMemoryExported';
  }
}

@immutable
class NativeEventMemoryItems extends NativeEvent {
  const NativeEventMemoryItems({required this.value}) : super();

  static NativeEventMemoryItems load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeEventMemoryItems(
      value: MemoryItems.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final MemoryItems value;

  NativeEventMemoryItems copyWith({MemoryItems? value}) {
    return NativeEventMemoryItems(value: value ?? this.value);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(16);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is NativeEventMemoryItems && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'value: $value'
          ')';
      return true;
    }());

    return fullString ?? 'NativeEventMemoryItems';
  }
}

final _nativeEventStreamController =
    StreamController<RustSignalPack<NativeEvent>>();
