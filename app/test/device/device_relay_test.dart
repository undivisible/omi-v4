import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/device.dart';

void main() {
  test(
    'desktop observes an unavailable relay instead of invoking mobile BLE',
    () async {
      final adapter = _FakeAdapter();
      final relay = DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: adapter,
      );

      expect(relay.capabilities.pairing, DeviceCapabilityState.unsupported);
      expect(
        (await relay.snapshots.first).phase,
        DeviceConnectionPhase.unavailable,
      );
      expect(() => relay.scan(), throwsA(isA<DeviceRelayUnavailable>()));
      expect(adapter.scanCount, 0);
    },
  );

  test(
    'mobile owner delegates pairing and strips invalid audio packets',
    () async {
      final adapter = _FakeAdapter();
      final relay = DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: adapter,
      );

      expect((await relay.scan()).single.id, 'omi-1');
      expect((await relay.connect('omi-1')).firmwareRevision, '3.0.20');
      expect(await relay.audioFrames('omi-1').toList(), hasLength(1));
      expect(adapter.scanCount, 1);
    },
  );

  test('missing native adapter exposes its exact unavailable state', () async {
    final relay = DeviceRelayService(
      role: DeviceRelayRole.mobileOwner,
      adapter: const UnavailableDeviceRelayAdapter(),
    );

    expect(
      relay.capabilities.audioStreaming,
      DeviceCapabilityState.adapterUnavailable,
    );
    expect(
      () => relay.connect('omi-1'),
      throwsA(isA<DeviceRelayUnavailable>()),
    );
  });
}

class _FakeAdapter implements DeviceRelayAdapter {
  int scanCount = 0;

  final RelayDevice device = const RelayDevice(
    id: 'omi-1',
    name: 'Omi',
    modelNumber: 'Omi Device',
    firmwareRevision: '3.0.20',
    hardwareRevision: 'Seeed Xiao BLE Sense',
    audioCodec: DeviceAudioCodec.opusFs320,
  );

  @override
  DeviceRelayCapabilities get capabilities => const DeviceRelayCapabilities(
    pairing: DeviceCapabilityState.available,
    metadata: DeviceCapabilityState.available,
    audioStreaming: DeviceCapabilityState.available,
  );

  @override
  Stream<DeviceRelaySnapshot> get snapshots => Stream.value(
    DeviceRelaySnapshot(
      phase: DeviceConnectionPhase.connected,
      capabilities: capabilities,
      device: device,
    ),
  );

  @override
  Stream<List<int>> audioPackets(String deviceId) => Stream.fromIterable([
    [0, 0, 0],
    [1, 0, 2, 42],
  ]);

  @override
  Stream<bool> connectionState(String deviceId) => const Stream.empty();

  @override
  Future<RelayDevice> connect(String deviceId) async => device;

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<RelayDevice>> scan() async {
    scanCount += 1;
    return [device];
  }
}
