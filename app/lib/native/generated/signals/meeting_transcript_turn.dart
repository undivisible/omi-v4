// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A finalized transcript segment attributed to a side of the call.
///
/// The assist panel renders these instead of raw transcript deltas so the
/// live rolling transcript shows who is speaking.
@immutable
class MeetingTranscriptTurn {
  const MeetingTranscriptTurn({
    required this.speaker,
    this.diarizedKey,
    required this.text,
    required this.occurredAtMs,
  });

  static MeetingTranscriptTurn deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MeetingTranscriptTurn(
      speaker: deserializer.deserializeString(),
      diarizedKey: TraitHelpers.deserializeOptionI64(deserializer),
      text: deserializer.deserializeString(),
      occurredAtMs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MeetingTranscriptTurn bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MeetingTranscriptTurn.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String speaker;
  final int? diarizedKey;
  final String text;
  final int occurredAtMs;

  MeetingTranscriptTurn copyWith({
    String? speaker,
    int? Function()? diarizedKey,
    String? text,
    int? occurredAtMs,
  }) {
    return MeetingTranscriptTurn(
      speaker: speaker ?? this.speaker,
      diarizedKey: diarizedKey == null ? this.diarizedKey : diarizedKey(),
      text: text ?? this.text,
      occurredAtMs: occurredAtMs ?? this.occurredAtMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(speaker);
    TraitHelpers.serializeOptionI64(diarizedKey, serializer);
    serializer.serializeString(text);
    serializer.serializeInt64(occurredAtMs);
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

    return other is MeetingTranscriptTurn &&
        speaker == other.speaker &&
        diarizedKey == other.diarizedKey &&
        text == other.text &&
        occurredAtMs == other.occurredAtMs;
  }

  @override
  int get hashCode => Object.hash(speaker, diarizedKey, text, occurredAtMs);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'speaker: [REDACTED], '
          'diarizedKey: $diarizedKey, '
          'text: [REDACTED], '
          'occurredAtMs: $occurredAtMs'
          ')';
      return true;
    }());

    return fullString ?? 'MeetingTranscriptTurn';
  }
}
