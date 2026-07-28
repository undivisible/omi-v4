// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class RewindVisualCaption {
  const RewindVisualCaption({
    required this.text,
    required this.source,
    required this.model,
    required this.descriptionVersion,
    required this.describedAtMs,
  });

  static RewindVisualCaption deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindVisualCaption(
      text: deserializer.deserializeString(),
      source: deserializer.deserializeString(),
      model: deserializer.deserializeString(),
      descriptionVersion: deserializer.deserializeUint32(),
      describedAtMs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RewindVisualCaption bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RewindVisualCaption.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String text;
  final String source;
  final String model;
  final int descriptionVersion;
  final int describedAtMs;

  RewindVisualCaption copyWith({
    String? text,
    String? source,
    String? model,
    int? descriptionVersion,
    int? describedAtMs,
  }) {
    return RewindVisualCaption(
      text: text ?? this.text,
      source: source ?? this.source,
      model: model ?? this.model,
      descriptionVersion: descriptionVersion ?? this.descriptionVersion,
      describedAtMs: describedAtMs ?? this.describedAtMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(text);
    serializer.serializeString(source);
    serializer.serializeString(model);
    serializer.serializeUint32(descriptionVersion);
    serializer.serializeInt64(describedAtMs);
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

    return other is RewindVisualCaption &&
        text == other.text &&
        source == other.source &&
        model == other.model &&
        descriptionVersion == other.descriptionVersion &&
        describedAtMs == other.describedAtMs;
  }

  @override
  int get hashCode =>
      Object.hash(text, source, model, descriptionVersion, describedAtMs);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'text: $text, '
          'source: $source, '
          'model: $model, '
          'descriptionVersion: $descriptionVersion, '
          'describedAtMs: $describedAtMs'
          ')';
      return true;
    }());

    return fullString ?? 'RewindVisualCaption';
  }
}
