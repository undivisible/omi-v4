// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class ComputerUseCapabilities {
  const ComputerUseCapabilities({
    required this.platform,
    required this.backend,
    required this.sessionIsolation,
    required this.permissions,
    required this.actions,
  });

  static ComputerUseCapabilities deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComputerUseCapabilities(
      platform: deserializer.deserializeString(),
      backend: deserializer.deserializeString(),
      sessionIsolation: ComputerUseSessionIsolationExtension.deserialize(
        deserializer,
      ),
      permissions: TraitHelpers.deserializeVectorComputerUsePermission(
        deserializer,
      ),
      actions: TraitHelpers.deserializeVectorComputerUseActionCapability(
        deserializer,
      ),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ComputerUseCapabilities bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ComputerUseCapabilities.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String platform;
  final String backend;
  final ComputerUseSessionIsolation sessionIsolation;
  final List<ComputerUsePermission> permissions;
  final List<ComputerUseActionCapability> actions;

  ComputerUseCapabilities copyWith({
    String? platform,
    String? backend,
    ComputerUseSessionIsolation? sessionIsolation,
    List<ComputerUsePermission>? permissions,
    List<ComputerUseActionCapability>? actions,
  }) {
    return ComputerUseCapabilities(
      platform: platform ?? this.platform,
      backend: backend ?? this.backend,
      sessionIsolation: sessionIsolation ?? this.sessionIsolation,
      permissions: permissions ?? this.permissions,
      actions: actions ?? this.actions,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(platform);
    serializer.serializeString(backend);
    sessionIsolation.serialize(serializer);
    TraitHelpers.serializeVectorComputerUsePermission(permissions, serializer);
    TraitHelpers.serializeVectorComputerUseActionCapability(
      actions,
      serializer,
    );
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

    return other is ComputerUseCapabilities &&
        platform == other.platform &&
        backend == other.backend &&
        sessionIsolation == other.sessionIsolation &&
        listEquals(permissions, other.permissions) &&
        listEquals(actions, other.actions);
  }

  @override
  int get hashCode =>
      Object.hash(platform, backend, sessionIsolation, permissions, actions);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'platform: $platform, '
          'backend: $backend, '
          'sessionIsolation: $sessionIsolation, '
          'permissions: $permissions, '
          'actions: $actions'
          ')';
      return true;
    }());

    return fullString ?? 'ComputerUseCapabilities';
  }
}
