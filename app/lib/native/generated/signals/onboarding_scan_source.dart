// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class OnboardingScanSource {
  const OnboardingScanSource({
    required this.source,
    required this.state,
    required this.itemsFound,
    required this.detail,
    this.memorySourceId,
  });

  static OnboardingScanSource deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = OnboardingScanSource(
      source: deserializer.deserializeString(),
      state: OnboardingScanStateExtension.deserialize(deserializer),
      itemsFound: deserializer.deserializeUint64(),
      detail: deserializer.deserializeString(),
      memorySourceId: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static OnboardingScanSource bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = OnboardingScanSource.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String source;
  final OnboardingScanState state;
  final Uint64 itemsFound;
  final String detail;
  final String? memorySourceId;

  OnboardingScanSource copyWith({
    String? source,
    OnboardingScanState? state,
    Uint64? itemsFound,
    String? detail,
    String? Function()? memorySourceId,
  }) {
    return OnboardingScanSource(
      source: source ?? this.source,
      state: state ?? this.state,
      itemsFound: itemsFound ?? this.itemsFound,
      detail: detail ?? this.detail,
      memorySourceId: memorySourceId == null
          ? this.memorySourceId
          : memorySourceId(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(source);
    state.serialize(serializer);
    serializer.serializeUint64(itemsFound);
    serializer.serializeString(detail);
    TraitHelpers.serializeOptionStr(memorySourceId, serializer);
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

    return other is OnboardingScanSource &&
        source == other.source &&
        state == other.state &&
        itemsFound == other.itemsFound &&
        detail == other.detail &&
        memorySourceId == other.memorySourceId;
  }

  @override
  int get hashCode =>
      Object.hash(source, state, itemsFound, detail, memorySourceId);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'source: $source, '
          'state: $state, '
          'itemsFound: $itemsFound, '
          'detail: $detail, '
          'memorySourceId: $memorySourceId'
          ')';
      return true;
    }());

    return fullString ?? 'OnboardingScanSource';
  }
}
