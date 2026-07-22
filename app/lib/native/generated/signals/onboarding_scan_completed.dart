// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class OnboardingScanCompleted {
  const OnboardingScanCompleted({
    required this.requestId,
    required this.sources,
  });

  static OnboardingScanCompleted deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = OnboardingScanCompleted(
      requestId: deserializer.deserializeString(),
      sources: TraitHelpers.deserializeVectorOnboardingScanSource(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static OnboardingScanCompleted bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = OnboardingScanCompleted.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final List<OnboardingScanSource> sources;

  OnboardingScanCompleted copyWith({
    String? requestId,
    List<OnboardingScanSource>? sources,
  }) {
    return OnboardingScanCompleted(
      requestId: requestId ?? this.requestId,
      sources: sources ?? this.sources,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    TraitHelpers.serializeVectorOnboardingScanSource(sources, serializer);
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

    return other is OnboardingScanCompleted &&
        requestId == other.requestId &&
        listEquals(sources, other.sources);
  }

  @override
  int get hashCode => Object.hash(requestId, sources);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'sources: $sources'
          ')';
      return true;
    }());

    return fullString ?? 'OnboardingScanCompleted';
  }
}
