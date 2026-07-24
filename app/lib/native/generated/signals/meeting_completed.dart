// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MeetingCompleted {
  const MeetingCompleted({
    required this.title,
    required this.summary,
    required this.actions,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.participants,
    required this.keyPoints,
    required this.decisions,
    required this.noteMarkdown,
    required this.metadataJson,
  });

  static MeetingCompleted deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MeetingCompleted(
      title: deserializer.deserializeString(),
      summary: deserializer.deserializeString(),
      actions: TraitHelpers.deserializeVectorStr(deserializer),
      startedAtMs: deserializer.deserializeInt64(),
      endedAtMs: deserializer.deserializeInt64(),
      participants: TraitHelpers.deserializeVectorStr(deserializer),
      keyPoints: TraitHelpers.deserializeVectorStr(deserializer),
      decisions: TraitHelpers.deserializeVectorStr(deserializer),
      noteMarkdown: deserializer.deserializeString(),
      metadataJson: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MeetingCompleted bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MeetingCompleted.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String title;
  final String summary;
  final List<String> actions;
  final int startedAtMs;
  final int endedAtMs;
  final List<String> participants;
  final List<String> keyPoints;
  final List<String> decisions;
  final String noteMarkdown;
  final String metadataJson;

  MeetingCompleted copyWith({
    String? title,
    String? summary,
    List<String>? actions,
    int? startedAtMs,
    int? endedAtMs,
    List<String>? participants,
    List<String>? keyPoints,
    List<String>? decisions,
    String? noteMarkdown,
    String? metadataJson,
  }) {
    return MeetingCompleted(
      title: title ?? this.title,
      summary: summary ?? this.summary,
      actions: actions ?? this.actions,
      startedAtMs: startedAtMs ?? this.startedAtMs,
      endedAtMs: endedAtMs ?? this.endedAtMs,
      participants: participants ?? this.participants,
      keyPoints: keyPoints ?? this.keyPoints,
      decisions: decisions ?? this.decisions,
      noteMarkdown: noteMarkdown ?? this.noteMarkdown,
      metadataJson: metadataJson ?? this.metadataJson,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(title);
    serializer.serializeString(summary);
    TraitHelpers.serializeVectorStr(actions, serializer);
    serializer.serializeInt64(startedAtMs);
    serializer.serializeInt64(endedAtMs);
    TraitHelpers.serializeVectorStr(participants, serializer);
    TraitHelpers.serializeVectorStr(keyPoints, serializer);
    TraitHelpers.serializeVectorStr(decisions, serializer);
    serializer.serializeString(noteMarkdown);
    serializer.serializeString(metadataJson);
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

    return other is MeetingCompleted &&
        title == other.title &&
        summary == other.summary &&
        listEquals(actions, other.actions) &&
        startedAtMs == other.startedAtMs &&
        endedAtMs == other.endedAtMs &&
        listEquals(participants, other.participants) &&
        listEquals(keyPoints, other.keyPoints) &&
        listEquals(decisions, other.decisions) &&
        noteMarkdown == other.noteMarkdown &&
        metadataJson == other.metadataJson;
  }

  @override
  int get hashCode => Object.hash(
    title,
    summary,
    actions,
    startedAtMs,
    endedAtMs,
    participants,
    keyPoints,
    decisions,
    noteMarkdown,
    metadataJson,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'title: $title, '
          'summary: $summary, '
          'actions: $actions, '
          'startedAtMs: $startedAtMs, '
          'endedAtMs: $endedAtMs, '
          'participants: $participants, '
          'keyPoints: $keyPoints, '
          'decisions: $decisions, '
          'noteMarkdown: $noteMarkdown, '
          'metadataJson: $metadataJson'
          ')';
      return true;
    }());

    return fullString ?? 'MeetingCompleted';
  }
}
