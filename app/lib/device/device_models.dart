enum DeviceRelayRole { mobileOwner, desktopObserver, webObserver }

enum DeviceConnectionPhase {
  unavailable,
  disconnected,
  scanning,
  connecting,
  connected,
  disconnecting,
  failed,
}

enum DeviceCapabilityState {
  available,
  permissionRequired,
  unsupported,
  adapterUnavailable,
}

enum DeviceAudioCodec {
  pcm8,
  pcm16,
  opus,
  opusFs320,
  unknown;

  static DeviceAudioCodec fromFirmwareId(int id) => switch (id) {
    1 => DeviceAudioCodec.pcm8,
    20 => DeviceAudioCodec.opus,
    21 => DeviceAudioCodec.opusFs320,
    _ => DeviceAudioCodec.unknown,
  };

  int get sampleRate => this == DeviceAudioCodec.pcm8 ? 8000 : 16000;
}

class DeviceRelayCapabilities {
  const DeviceRelayCapabilities({
    required this.pairing,
    required this.metadata,
    required this.audioStreaming,
  });

  const DeviceRelayCapabilities.unavailable(DeviceCapabilityState state)
    : pairing = state,
      metadata = state,
      audioStreaming = state;

  final DeviceCapabilityState pairing;
  final DeviceCapabilityState metadata;
  final DeviceCapabilityState audioStreaming;
}

class RelayDevice {
  const RelayDevice({
    required this.id,
    required this.name,
    this.signalStrength,
    this.modelNumber,
    this.firmwareRevision,
    this.hardwareRevision,
    this.manufacturerName,
    this.serialNumber,
    this.batteryLevel,
    this.audioCodec = DeviceAudioCodec.unknown,
    this.systemConnected = false,
  });

  final String id;
  final String name;
  final int? signalStrength;
  final String? modelNumber;
  final String? firmwareRevision;
  final String? hardwareRevision;
  final String? manufacturerName;
  final String? serialNumber;
  final int? batteryLevel;
  final DeviceAudioCodec audioCodec;
  final bool systemConnected;
}

class DeviceRelaySnapshot {
  const DeviceRelaySnapshot({
    required this.phase,
    required this.capabilities,
    this.device,
    this.message,
  });

  final DeviceConnectionPhase phase;
  final DeviceRelayCapabilities capabilities;
  final RelayDevice? device;
  final String? message;
}

class DeviceRelayUnavailable implements Exception {
  const DeviceRelayUnavailable(this.operation, this.state);

  final String operation;
  final DeviceCapabilityState state;

  @override
  String toString() => 'DeviceRelayUnavailable($operation, ${state.name})';
}
