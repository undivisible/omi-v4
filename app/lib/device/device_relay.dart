import 'dart:async';

import 'device_audio_frame.dart';
import 'device_models.dart';

abstract interface class DeviceRelayHaptics {
  Future<bool> sendHaptic(int level);
}

/// Drives the pendant capture-aware LED (blue while capturing, red while idle).
/// The firmware team is adding an app-writable characteristic; adapters that
/// cannot reach it return false so the UI falls back to connection-LED
/// semantics without failing.
abstract interface class DeviceRelayLed {
  Future<bool> writeCaptureLed(bool capturing);

  /// False once the adapter knows the connected firmware has no capture-LED
  /// characteristic. Adapters start optimistic and learn from the first write,
  /// so this only turns false when the pendant genuinely cannot be driven.
  bool get captureLedSupported;
}

/// Commands the pendant to sleep/power off (settings characteristic 19b10014).
/// Adapters return false when the write is unsupported.
abstract interface class DeviceRelaySleep {
  Future<bool> sleepDevice();
}

/// Writes the firmware rename characteristic (19b10016) as a persisted UTF-8
/// name. Adapters return false when the write is unsupported so the rename
/// field can hide or disable itself gracefully.
abstract interface class DeviceRelayRename {
  Future<bool> renameDevice(String name);
}

abstract interface class DeviceRelayAdapter {
  DeviceRelayCapabilities get capabilities;
  Stream<DeviceRelaySnapshot> get snapshots;
  Future<List<RelayDevice>> scan();
  Future<RelayDevice> connect(String deviceId);
  Future<void> disconnect();
  Stream<List<int>> audioPackets(String deviceId);
  Stream<bool> connectionState(String deviceId);
}

class DeviceRelayService {
  DeviceRelayService({required this.role, required this.adapter}) {
    // Snapshots are broadcast with no replay: a screen that mounts after the
    // connect (onboarding pairs, then the home screen appears) would other-
    // wise render "Disconnected" until the next state change. Cache the last
    // snapshot so late listeners can seed their initial state.
    if (role == DeviceRelayRole.mobileOwner) {
      adapter.snapshots.listen(
        (snapshot) => _lastSnapshot = snapshot,
        onError: (Object _) {},
      );
    }
  }

  final DeviceRelayRole role;
  final DeviceRelayAdapter adapter;
  DeviceRelaySnapshot? _lastSnapshot;

  DeviceRelaySnapshot? get lastSnapshot => _lastSnapshot;

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

  Future<bool> sendHaptic(int level) async {
    if (role != DeviceRelayRole.mobileOwner) return false;
    final Object haptics = adapter;
    if (haptics is! DeviceRelayHaptics) return false;
    try {
      return await haptics.sendHaptic(level);
    } catch (_) {
      return false;
    }
  }

  /// Reflects the capture state on the pendant LED. Returns false (a no-op the
  /// caller can ignore) when the role or adapter cannot drive the LED, which
  /// is the expected path until the firmware ships the writable characteristic.
  Future<bool> writeCaptureLed(bool capturing) async {
    if (role != DeviceRelayRole.mobileOwner) return false;
    final Object led = adapter;
    if (led is! DeviceRelayLed) return false;
    try {
      return await led.writeCaptureLed(capturing);
    } catch (_) {
      return false;
    }
  }

  /// Commands the connected pendant to sleep. Returns false when the role or
  /// adapter cannot reach the sleep characteristic.
  Future<bool> sleepDevice() async {
    if (role != DeviceRelayRole.mobileOwner) return false;
    final Object sleep = adapter;
    if (sleep is! DeviceRelaySleep) return false;
    try {
      return await sleep.sleepDevice();
    } catch (_) {
      return false;
    }
  }

  /// Renames the connected pendant. Returns false when renaming is
  /// unsupported so the settings field can disable itself.
  Future<bool> renameDevice(String name) async {
    if (role != DeviceRelayRole.mobileOwner) return false;
    final Object rename = adapter;
    if (rename is! DeviceRelayRename) return false;
    try {
      return await rename.renameDevice(name);
    } catch (_) {
      return false;
    }
  }

  bool get supportsRename =>
      role == DeviceRelayRole.mobileOwner && adapter is DeviceRelayRename;

  /// Whether the pendant LED can be driven from the app at all. Old firmware
  /// predates the capture-state characteristic, and a relay that cannot write
  /// it must not let the UI claim the light follows the switch.
  bool get captureLedSupported {
    if (role != DeviceRelayRole.mobileOwner) return false;
    final Object led = adapter;
    return led is DeviceRelayLed && led.captureLedSupported;
  }

  Stream<DeviceAudioFrame> audioFrames(String deviceId) {
    _require(
      DeviceCapabilityState.available,
      capabilities.audioStreaming,
      'audioFrames',
    );
    return decodeDeviceAudioFrames(adapter.audioPackets(deviceId));
  }

  Stream<bool> connectionState(String deviceId) =>
      role == DeviceRelayRole.mobileOwner
      ? adapter.connectionState(deviceId)
      : const Stream.empty();

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
  Stream<bool> connectionState(String deviceId) => const Stream.empty();

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
