// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The single instruction the capture surface is allowed to carry out.
///
/// `Preview` is the only one that reads pixels, and it is never issued for a
/// screen the privacy rules refused. `Encode` is never issued for a frame the
/// similarity gate rejected. Between them, no frame is ever encoded and then
/// thrown away.
abstract class RewindDirective {
  const RewindDirective();

  void serialize(BinarySerializer serializer);

  static RewindDirective deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return RewindDirectivePreview.load(deserializer);
      case 1:
        return RewindDirectiveIdle.load(deserializer);
      case 2:
        return RewindDirectiveEncode.load(deserializer);
      case 3:
        return RewindDirectiveDiscard.load(deserializer);
      case 4:
        return RewindDirectiveStored.load(deserializer);
      default:
        throw Exception(
          'Unknown variant index for RewindDirective: ' + index.toString(),
        );
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static RewindDirective bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RewindDirective.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

@immutable
class RewindDirectivePreview extends RewindDirective {
  const RewindDirectivePreview() : super();

  static RewindDirectivePreview load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindDirectivePreview();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindDirectivePreview;
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

    return fullString ?? 'RewindDirectivePreview';
  }
}

@immutable
class RewindDirectiveIdle extends RewindDirective {
  const RewindDirectiveIdle({required this.reason}) : super();

  static RewindDirectiveIdle load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindDirectiveIdle(
      reason: RewindSkipReasonExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final RewindSkipReason reason;

  RewindDirectiveIdle copyWith({RewindSkipReason? reason}) {
    return RewindDirectiveIdle(reason: reason ?? this.reason);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    reason.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindDirectiveIdle && reason == other.reason;
  }

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'reason: $reason'
          ')';
      return true;
    }());

    return fullString ?? 'RewindDirectiveIdle';
  }
}

@immutable
class RewindDirectiveEncode extends RewindDirective {
  const RewindDirectiveEncode({required this.recognizeText}) : super();

  static RewindDirectiveEncode load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindDirectiveEncode(
      recognizeText: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final bool recognizeText;

  RewindDirectiveEncode copyWith({bool? recognizeText}) {
    return RewindDirectiveEncode(
      recognizeText: recognizeText ?? this.recognizeText,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.serializeBool(recognizeText);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindDirectiveEncode &&
        recognizeText == other.recognizeText;
  }

  @override
  int get hashCode => recognizeText.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'recognizeText: $recognizeText'
          ')';
      return true;
    }());

    return fullString ?? 'RewindDirectiveEncode';
  }
}

@immutable
class RewindDirectiveDiscard extends RewindDirective {
  const RewindDirectiveDiscard({required this.reason}) : super();

  static RewindDirectiveDiscard load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindDirectiveDiscard(
      reason: RewindSkipReasonExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final RewindSkipReason reason;

  RewindDirectiveDiscard copyWith({RewindSkipReason? reason}) {
    return RewindDirectiveDiscard(reason: reason ?? this.reason);
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    reason.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RewindDirectiveDiscard && reason == other.reason;
  }

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'reason: $reason'
          ')';
      return true;
    }());

    return fullString ?? 'RewindDirectiveDiscard';
  }
}

@immutable
class RewindDirectiveStored extends RewindDirective {
  const RewindDirectiveStored() : super();

  static RewindDirectiveStored load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindDirectiveStored();
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

    return other is RewindDirectiveStored;
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

    return fullString ?? 'RewindDirectiveStored';
  }
}
