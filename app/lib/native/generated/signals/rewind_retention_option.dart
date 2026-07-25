// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class RewindRetentionOption {
  const RewindRetentionOption({
    required this.maxAgeDays,
    required this.maxBytes,
    required this.label,
  });

  static RewindRetentionOption deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindRetentionOption(
      maxAgeDays: deserializer.deserializeInt64(),
      maxBytes: deserializer.deserializeUint64(),
      label: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RewindRetentionOption bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RewindRetentionOption.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int maxAgeDays;
  final Uint64 maxBytes;
  final String label;

  RewindRetentionOption copyWith({
    int? maxAgeDays,
    Uint64? maxBytes,
    String? label,
  }) {
    return RewindRetentionOption(
      maxAgeDays: maxAgeDays ?? this.maxAgeDays,
      maxBytes: maxBytes ?? this.maxBytes,
      label: label ?? this.label,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeInt64(maxAgeDays);
    serializer.serializeUint64(maxBytes);
    serializer.serializeString(label);
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

    return other is RewindRetentionOption &&
        maxAgeDays == other.maxAgeDays &&
        maxBytes == other.maxBytes &&
        label == other.label;
  }

  @override
  int get hashCode => Object.hash(maxAgeDays, maxBytes, label);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'maxAgeDays: $maxAgeDays, '
          'maxBytes: $maxBytes, '
          'label: $label'
          ')';
      return true;
    }());

    return fullString ?? 'RewindRetentionOption';
  }
}
