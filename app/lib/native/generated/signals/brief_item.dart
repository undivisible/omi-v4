// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One current, flattened to the few facts the brief may state. Mirrors
/// [`crate::brief::BriefItem`], which is the shape the prompt is built from.
@immutable
class BriefItem {
  const BriefItem({
    required this.title,
    required this.when,
    required this.detail,
    required this.nextStep,
  });

  static BriefItem deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = BriefItem(
      title: deserializer.deserializeString(),
      when: deserializer.deserializeString(),
      detail: deserializer.deserializeString(),
      nextStep: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static BriefItem bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = BriefItem.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String title;
  final String when;
  final String detail;
  final String nextStep;

  BriefItem copyWith({
    String? title,
    String? when,
    String? detail,
    String? nextStep,
  }) {
    return BriefItem(
      title: title ?? this.title,
      when: when ?? this.when,
      detail: detail ?? this.detail,
      nextStep: nextStep ?? this.nextStep,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(title);
    serializer.serializeString(when);
    serializer.serializeString(detail);
    serializer.serializeString(nextStep);
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

    return other is BriefItem &&
        title == other.title &&
        when == other.when &&
        detail == other.detail &&
        nextStep == other.nextStep;
  }

  @override
  int get hashCode => Object.hash(title, when, detail, nextStep);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'title: $title, '
          'when: $when, '
          'detail: $detail, '
          'nextStep: $nextStep'
          ')';
      return true;
    }());

    return fullString ?? 'BriefItem';
  }
}
