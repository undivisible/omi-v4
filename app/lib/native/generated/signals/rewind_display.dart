// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class RewindDisplay {
  const RewindDisplay({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.scale,
    required this.primary,
  });

  static RewindDisplay deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindDisplay(
      id: deserializer.deserializeString(),
      name: deserializer.deserializeString(),
      x: deserializer.deserializeInt32(),
      y: deserializer.deserializeInt32(),
      width: deserializer.deserializeUint32(),
      height: deserializer.deserializeUint32(),
      scale: deserializer.deserializeFloat32(),
      primary: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RewindDisplay bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RewindDisplay.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String id;
  final String name;
  final int x;
  final int y;
  final int width;
  final int height;
  final double scale;
  final bool primary;

  RewindDisplay copyWith({
    String? id,
    String? name,
    int? x,
    int? y,
    int? width,
    int? height,
    double? scale,
    bool? primary,
  }) {
    return RewindDisplay(
      id: id ?? this.id,
      name: name ?? this.name,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      scale: scale ?? this.scale,
      primary: primary ?? this.primary,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(id);
    serializer.serializeString(name);
    serializer.serializeInt32(x);
    serializer.serializeInt32(y);
    serializer.serializeUint32(width);
    serializer.serializeUint32(height);
    serializer.serializeFloat32(scale);
    serializer.serializeBool(primary);
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

    return other is RewindDisplay &&
        id == other.id &&
        name == other.name &&
        x == other.x &&
        y == other.y &&
        width == other.width &&
        height == other.height &&
        scale == other.scale &&
        primary == other.primary;
  }

  @override
  int get hashCode =>
      Object.hash(id, name, x, y, width, height, scale, primary);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'id: $id, '
          'name: $name, '
          'x: $x, '
          'y: $y, '
          'width: $width, '
          'height: $height, '
          'scale: $scale, '
          'primary: $primary'
          ')';
      return true;
    }());

    return fullString ?? 'RewindDisplay';
  }
}
