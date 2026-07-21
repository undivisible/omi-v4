import 'dart:async';

import 'device_audio_frame.dart';
import 'device_models.dart';

abstract interface class DeviceRelayAdapter {
  DeviceRelayCapabilities get capabilities;
  Stream<DeviceRelaySnapshot> get snapshots;
  Future<List<RelayDevice>> scan();
  Future<RelayDevice> connect(String deviceId);
  Future<void> disconnect();
  Stream<List<int>> audioPackets(String deviceId);
}

class DeviceRelayService {
  DeviceRelayService({required this.role, required this.adapter});

  final DeviceRelayRole role;
  final DeviceRelayAdapter adapter;

  DeviceRelayCapabilities get capabilities =>
      role == DeviceRelayRole.mobileOwner
      ? adapter.capabilities
      : const DeviceRelayCapabilities.unavailable(
          DeviceCapabilityState.unsupported,
        );

  Stream<DeviceRelaySnapshot> get snapshots =>
      role == DeviceRelayRole.mobileOwner
      ? adapter.snapshots
      : Stream.value(
          DeviceRelaySnapshot(
            phase: DeviceConnectionPhase.unavailable,
            capabilities: capabilities,
          ),
        );

  Future<List<RelayDevice>> scan() {
    _require(DeviceCapabilityState.available, capabilities.pairing, 'scan');
    return adapter.scan();
  }

  Future<RelayDevice> connect(String deviceId) {
    _require(DeviceCapabilityState.available, capabilities.pairing, 'connect');
    return adapter.connect(deviceId);
  }

  Future<void> disconnect() {
    _require(
      DeviceCapabilityState.available,
      capabilities.pairing,
      'disconnect',
    );
    return adapter.disconnect();
  }

  Stream<DeviceAudioFrame> audioFrames(String deviceId) {
    _require(
      DeviceCapabilityState.available,
      capabilities.audioStreaming,
      'audioFrames',
    );
    return adapter
        .audioPackets(deviceId)
        .map(DeviceAudioFrame.decode)
        .where((frame) => frame != null)
        .cast();
  }

  void _require(
    DeviceCapabilityState expected,
    DeviceCapabilityState actual,
    String operation,
  ) {
    if (actual != expected) throw DeviceRelayUnavailable(operation, actual);
  }
}

class UnavailableDeviceRelayAdapter implements DeviceRelayAdapter {
  const UnavailableDeviceRelayAdapter({
    this.state = DeviceCapabilityState.adapterUnavailable,
  });

  final DeviceCapabilityState state;

  @override
  DeviceRelayCapabilities get capabilities =>
      DeviceRelayCapabilities.unavailable(state);

  @override
  Stream<DeviceRelaySnapshot> get snapshots => Stream.value(
    DeviceRelaySnapshot(
      phase: DeviceConnectionPhase.unavailable,
      capabilities: capabilities,
      message: state.name,
    ),
  );

  @override
  Stream<List<int>> audioPackets(String deviceId) => const Stream.empty();

  @override
  Future<RelayDevice> connect(String deviceId) =>
      Future.error(DeviceRelayUnavailable('connect', state));

  @override
  Future<void> disconnect() =>
      Future.error(DeviceRelayUnavailable('disconnect', state));

  @override
  Future<List<RelayDevice>> scan() =>
      Future.error(DeviceRelayUnavailable('scan', state));
}
