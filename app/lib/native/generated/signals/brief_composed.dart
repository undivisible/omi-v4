// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The answer to a [`Command::ComposeBrief`]. `crepus` carries a document the
/// renderer has already been checked to accept, or `None` when nothing was
/// composed — no generator, a model failure, a timeout, a cancellation, or a
/// document the renderer would refuse. `None` is not an error and never
/// raises one: the client's hand-built brief is the answer then.
@immutable
class BriefComposed {
  const BriefComposed({required this.requestId, this.crepus});

  static BriefComposed deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = BriefComposed(
      requestId: deserializer.deserializeString(),
      crepus: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static BriefComposed bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = BriefComposed.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String? crepus;

  BriefComposed copyWith({String? requestId, String? Function()? crepus}) {
    return BriefComposed(
      requestId: requestId ?? this.requestId,
      crepus: crepus == null ? this.crepus : crepus(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    TraitHelpers.serializeOptionStr(crepus, serializer);
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

    return other is BriefComposed &&
        requestId == other.requestId &&
        crepus == other.crepus;
  }

  @override
  int get hashCode => Object.hash(requestId, crepus);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'crepus: $crepus'
          ')';
      return true;
    }());

    return fullString ?? 'BriefComposed';
  }
}
