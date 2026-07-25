// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

abstract class RewindPayload {
  const RewindPayload();

  void serialize(BinarySerializer serializer);

  static RewindPayload deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return RewindPayloadDirective.load(deserializer);
      case 1:
        return RewindPayloadStatus.load(deserializer);
      case 2:
        return RewindPayloadFrames.load(deserializer);
      case 3:
        return RewindPayloadUnavailable.load(deserializer);
      default:
        throw Exception(
          'Unknown variant index for RewindPayload: ' + index.toString(),
        );
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static RewindPayload bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RewindPayload.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

@immutable
class RewindPayloadDirective extends RewindPayload {
  const RewindPayloadDirective({required this.stepId, required this.directive})
    : super();

  static RewindPayloadDirective load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindPayloadDirective(
      stepId: deserializer.deserializeUint64(),
      directive: RewindDirective.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 stepId;
  final RewindDirective directive;

  RewindPayloadDirective copyWith({
    Uint64? stepId,
    RewindDirective? directive,
  }) {
    return RewindPayloadDirective(
      stepId: stepId ?? this.stepId,
      directive: directive ?? this.directive,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeUint64(stepId);
    directive.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindPayloadDirective &&
        stepId == other.stepId &&
        directive == other.directive;
  }

  @override
  int get hashCode => Object.hash(stepId, directive);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'stepId: $stepId, '
          'directive: $directive'
          ')';
      return true;
    }());

    return fullString ?? 'RewindPayloadDirective';
  }
}

@immutable
class RewindPayloadStatus extends RewindPayload {
  const RewindPayloadStatus({required this.value}) : super();

  static RewindPayloadStatus load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindPayloadStatus(
      value: RewindStatus.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final RewindStatus value;

  RewindPayloadStatus copyWith({RewindStatus? value}) {
    return RewindPayloadStatus(value: value ?? this.value);
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

    return other is RewindPayloadStatus && value == other.value;
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

    return fullString ?? 'RewindPayloadStatus';
  }
}

@immutable
class RewindPayloadFrames extends RewindPayload {
  const RewindPayloadFrames({required this.frames}) : super();

  static RewindPayloadFrames load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindPayloadFrames(
      frames: TraitHelpers.deserializeVectorRewindFrameRecord(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<RewindFrameRecord> frames;

  RewindPayloadFrames copyWith({List<RewindFrameRecord>? frames}) {
    return RewindPayloadFrames(frames: frames ?? this.frames);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    TraitHelpers.serializeVectorRewindFrameRecord(frames, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindPayloadFrames && listEquals(frames, other.frames);
  }

  @override
  int get hashCode => frames.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'frames: $frames'
          ')';
      return true;
    }());

    return fullString ?? 'RewindPayloadFrames';
  }
}

@immutable
class RewindPayloadUnavailable extends RewindPayload {
  const RewindPayloadUnavailable({required this.detail}) : super();

  static RewindPayloadUnavailable load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindPayloadUnavailable(
      detail: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String detail;

  RewindPayloadUnavailable copyWith({String? detail}) {
    return RewindPayloadUnavailable(detail: detail ?? this.detail);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    serializer.serializeString(detail);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindPayloadUnavailable && detail == other.detail;
  }

  @override
  int get hashCode => detail.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'detail: $detail'
          ')';
      return true;
    }());

    return fullString ?? 'RewindPayloadUnavailable';
  }
}
