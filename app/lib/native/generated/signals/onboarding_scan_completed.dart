// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class OnboardingScanCompleted {
  const OnboardingScanCompleted({
    required this.requestId,
    required this.sources,
    this.summary,
    this.detectedName,
    required this.detectedLanguages,
  });

  static OnboardingScanCompleted deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = OnboardingScanCompleted(
      requestId: deserializer.deserializeString(),
      sources: TraitHelpers.deserializeVectorOnboardingScanSource(deserializer),
      summary: TraitHelpers.deserializeOptionStr(deserializer),
      detectedName: TraitHelpers.deserializeOptionStr(deserializer),
      detectedLanguages: TraitHelpers.deserializeVectorStr(deserializer),
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
  final String? detectedName;
  final List<String> detectedLanguages;

  OnboardingScanCompleted copyWith({
    String? requestId,
    List<OnboardingScanSource>? sources,
    String? Function()? summary,
    String? Function()? detectedName,
    List<String>? detectedLanguages,
  }) {
    return OnboardingScanCompleted(
      requestId: requestId ?? this.requestId,
      sources: sources ?? this.sources,
      summary: summary == null ? this.summary : summary(),
      detectedName: detectedName == null ? this.detectedName : detectedName(),
      detectedLanguages: detectedLanguages ?? this.detectedLanguages,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    TraitHelpers.serializeVectorOnboardingScanSource(sources, serializer);
    TraitHelpers.serializeOptionStr(summary, serializer);
    TraitHelpers.serializeOptionStr(detectedName, serializer);
    TraitHelpers.serializeVectorStr(detectedLanguages, serializer);
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
        summary == other.summary &&
        detectedName == other.detectedName &&
        listEquals(detectedLanguages, other.detectedLanguages);
  }

  @override
  int get hashCode =>
      Object.hash(requestId, sources, summary, detectedName, detectedLanguages);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'sources: $sources, '
          'summary: [REDACTED], '
          'detectedName: [REDACTED], '
          'detectedLanguages: $detectedLanguages'
          ')';
      return true;
    }());

    return fullString ?? 'OnboardingScanCompleted';
  }
}
