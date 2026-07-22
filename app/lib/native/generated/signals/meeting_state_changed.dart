// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class MeetingStateChanged {
  const MeetingStateChanged({required this.active, this.suggestedTitle});

  static MeetingStateChanged deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MeetingStateChanged(
      active: deserializer.deserializeBool(),
      suggestedTitle: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MeetingStateChanged bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MeetingStateChanged.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final bool active;
  final String? suggestedTitle;

  MeetingStateChanged copyWith({
    bool? active,
    String? Function()? suggestedTitle,
  }) {
    return MeetingStateChanged(
      active: active ?? this.active,
      suggestedTitle: suggestedTitle == null
          ? this.suggestedTitle
          : suggestedTitle(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeBool(active);
    TraitHelpers.serializeOptionStr(suggestedTitle, serializer);
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

    return other is MeetingStateChanged &&
        active == other.active &&
        suggestedTitle == other.suggestedTitle;
  }

  @override
  int get hashCode => Object.hash(active, suggestedTitle);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'active: $active, '
          'suggestedTitle: $suggestedTitle'
          ')';
      return true;
    }());

    return fullString ?? 'MeetingStateChanged';
  }
}
