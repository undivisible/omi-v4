// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MeetingCompleted {
  const MeetingCompleted({
    required this.title,
    required this.summary,
    required this.actions,
  });

  static MeetingCompleted deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MeetingCompleted(
      title: deserializer.deserializeString(),
      summary: deserializer.deserializeString(),
      actions: TraitHelpers.deserializeVectorStr(deserializer),
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

  MeetingCompleted copyWith({
    String? title,
    String? summary,
    List<String>? actions,
  }) {
    return MeetingCompleted(
      title: title ?? this.title,
      summary: summary ?? this.summary,
      actions: actions ?? this.actions,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(title);
    serializer.serializeString(summary);
    TraitHelpers.serializeVectorStr(actions, serializer);
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
        listEquals(actions, other.actions);
  }

  @override
  int get hashCode => Object.hash(title, summary, actions);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'title: $title, '
          'summary: $summary, '
          'actions: $actions'
          ')';
      return true;
    }());

    return fullString ?? 'MeetingCompleted';
  }
}
