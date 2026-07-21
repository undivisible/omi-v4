// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

abstract class ComputerUseAction {
  const ComputerUseAction();

  void serialize(BinarySerializer serializer);

  static ComputerUseAction deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return ComputerUseActionClick.load(deserializer);
      case 1:
        return ComputerUseActionTypeText.load(deserializer);
      default:
        throw Exception(
          'Unknown variant index for ComputerUseAction: ' + index.toString(),
        );
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static ComputerUseAction bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ComputerUseAction.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

@immutable
class ComputerUseActionClick extends ComputerUseAction {
  const ComputerUseActionClick({
    required this.x,
    required this.y,
    required this.button,
    required this.count,
  }) : super();

  static ComputerUseActionClick load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComputerUseActionClick(
      x: deserializer.deserializeInt64(),
      y: deserializer.deserializeInt64(),
      button: MouseButtonExtension.deserialize(deserializer),
      count: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final int x;
  final int y;
  final MouseButton button;
  final int count;

  ComputerUseActionClick copyWith({
    int? x,
    int? y,
    MouseButton? button,
    int? count,
  }) {
    return ComputerUseActionClick(
      x: x ?? this.x,
      y: y ?? this.y,
      button: button ?? this.button,
      count: count ?? this.count,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeInt64(x);
    serializer.serializeInt64(y);
    button.serialize(serializer);
    serializer.serializeUint32(count);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ComputerUseActionClick &&
        x == other.x &&
        y == other.y &&
        button == other.button &&
        count == other.count;
  }

  @override
  int get hashCode => Object.hash(x, y, button, count);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'x: $x, '
          'y: $y, '
          'button: $button, '
          'count: $count'
          ')';
      return true;
    }());

    return fullString ?? 'ComputerUseActionClick';
  }
}

@immutable
class ComputerUseActionTypeText extends ComputerUseAction {
  const ComputerUseActionTypeText({
    required this.text,
    required this.clear,
    required this.pressReturn,
    this.delayMs,
  }) : super();

  static ComputerUseActionTypeText load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComputerUseActionTypeText(
      text: deserializer.deserializeString(),
      clear: deserializer.deserializeBool(),
      pressReturn: deserializer.deserializeBool(),
      delayMs: TraitHelpers.deserializeOptionU64(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String text;
  final bool clear;
  final bool pressReturn;
  final Uint64? delayMs;

  ComputerUseActionTypeText copyWith({
    String? text,
    bool? clear,
    bool? pressReturn,
    Uint64? Function()? delayMs,
  }) {
    return ComputerUseActionTypeText(
      text: text ?? this.text,
      clear: clear ?? this.clear,
      pressReturn: pressReturn ?? this.pressReturn,
      delayMs: delayMs == null ? this.delayMs : delayMs(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(text);
    serializer.serializeBool(clear);
    serializer.serializeBool(pressReturn);
    TraitHelpers.serializeOptionU64(delayMs, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ComputerUseActionTypeText &&
        text == other.text &&
        clear == other.clear &&
        pressReturn == other.pressReturn &&
        delayMs == other.delayMs;
  }

  @override
  int get hashCode => Object.hash(text, clear, pressReturn, delayMs);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'text: [REDACTED], '
          'clear: $clear, '
          'pressReturn: $pressReturn, '
          'delayMs: $delayMs'
          ')';
      return true;
    }());

    return fullString ?? 'ComputerUseActionTypeText';
  }
}
