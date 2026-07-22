// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class OnboardingScanCompleted {
  const OnboardingScanCompleted({
    required this.requestId,
    required this.sources,
    this.summary,
  });

  static OnboardingScanCompleted deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = OnboardingScanCompleted(
      requestId: deserializer.deserializeString(),
      sources: TraitHelpers.deserializeVectorOnboardingScanSource(deserializer),
      summary: TraitHelpers.deserializeOptionStr(deserializer),
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
  final String? summary;

  OnboardingScanCompleted copyWith({
    String? requestId,
    List<OnboardingScanSource>? sources,
    String? Function()? summary,
  }) {
    return OnboardingScanCompleted(
      requestId: requestId ?? this.requestId,
      sources: sources ?? this.sources,
      summary: summary == null ? this.summary : summary(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    TraitHelpers.serializeVectorOnboardingScanSource(sources, serializer);
    TraitHelpers.serializeOptionStr(summary, serializer);
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
        listEquals(sources, other.sources) &&
        summary == other.summary;
  }

  @override
  int get hashCode => Object.hash(requestId, sources, summary);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'sources: $sources, '
          'summary: [REDACTED]'
          ')';
      return true;
    }());

    return fullString ?? 'OnboardingScanCompleted';
  }
}
