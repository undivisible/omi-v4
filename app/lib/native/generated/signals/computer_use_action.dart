// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

abstract class ComputerUseAction {
  const ComputerUseAction();

  void serialize(BinarySerializer serializer);

  static ComputerUseAction deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return ComputerUseActionInvoke.load(deserializer);
      case 1:
        return ComputerUseActionSetValue.load(deserializer);
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
class ComputerUseActionInvoke extends ComputerUseAction {
  const ComputerUseActionInvoke({
    required this.targetName,
    required this.backgroundOnly,
  }) : super();

  static ComputerUseActionInvoke load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComputerUseActionInvoke(
      targetName: deserializer.deserializeString(),
      backgroundOnly: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String targetName;
  final bool backgroundOnly;

  ComputerUseActionInvoke copyWith({String? targetName, bool? backgroundOnly}) {
    return ComputerUseActionInvoke(
      targetName: targetName ?? this.targetName,
      backgroundOnly: backgroundOnly ?? this.backgroundOnly,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeString(targetName);
    serializer.serializeBool(backgroundOnly);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ComputerUseActionInvoke &&
        targetName == other.targetName &&
        backgroundOnly == other.backgroundOnly;
  }

  @override
  int get hashCode => Object.hash(targetName, backgroundOnly);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'targetName: [REDACTED], '
          'backgroundOnly: $backgroundOnly'
          ')';
      return true;
    }());

    return fullString ?? 'ComputerUseActionInvoke';
  }
}

@immutable
class ComputerUseActionSetValue extends ComputerUseAction {
  const ComputerUseActionSetValue({
    required this.targetName,
    required this.value,
    required this.backgroundOnly,
  }) : super();

  static ComputerUseActionSetValue load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComputerUseActionSetValue(
      targetName: deserializer.deserializeString(),
      value: deserializer.deserializeString(),
      backgroundOnly: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String targetName;
  final String value;
  final bool backgroundOnly;

  ComputerUseActionSetValue copyWith({
    String? targetName,
    String? value,
    bool? backgroundOnly,
  }) {
    return ComputerUseActionSetValue(
      targetName: targetName ?? this.targetName,
      value: value ?? this.value,
      backgroundOnly: backgroundOnly ?? this.backgroundOnly,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(targetName);
    serializer.serializeString(value);
    serializer.serializeBool(backgroundOnly);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ComputerUseActionSetValue &&
        targetName == other.targetName &&
        value == other.value &&
        backgroundOnly == other.backgroundOnly;
  }

  @override
  int get hashCode => Object.hash(targetName, value, backgroundOnly);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'targetName: [REDACTED], '
          'value: [REDACTED], '
          'backgroundOnly: $backgroundOnly'
          ')';
      return true;
    }());

    return fullString ?? 'ComputerUseActionSetValue';
  }
}
