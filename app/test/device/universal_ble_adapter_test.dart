import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/device.dart';
import 'package:universal_ble/universal_ble.dart';

const _omiService = '19b10000-e8f2-537e-4f6c-d104768a1214';

void main() {
  late _FakeBlePlatform platform;
  late UniversalBleDeviceRelayAdapter adapter;

  setUp(() {
    platform = _FakeBlePlatform();
    UniversalBle.setInstance(platform);
    adapter = UniversalBleDeviceRelayAdapter(scanSettle: Duration.zero);
  });

  test('scan surfaces a system-connected Omi that never advertises', () async {
    platform.systemDevices = [
      BleDevice(
        deviceId: 'omi-system',
        name: 'Omi',
        services: const [_omiService],
        isSystemDevice: true,
      ),
    ];

    final found = await adapter.scan();

    expect(found, hasLength(1));
    expect(found.single.id, 'omi-system');
    expect(found.single.systemConnected, isTrue);
    expect(platform.startScanCalls, 1);
  });

  test('scan marks advertising devices as not system-connected', () async {
    platform.advertisedDevices = [
      BleDevice(
        deviceId: 'omi-adv',
        name: 'Omi',
        rssi: -40,
        services: const [_omiService],
      ),
    ];

    final found = await adapter.scan();

    expect(found.single.id, 'omi-adv');
    expect(found.single.systemConnected, isFalse);
  });

  test(
    'connect attaches to a system-connected device without a scan',
    () async {
      platform.systemDevices = [
        BleDevice(
          deviceId: 'omi-system',
          name: 'Omi',
          services: const [_omiService],
        ),
      ];

      final device = await adapter.connect('omi-system');

      expect(device.id, 'omi-system');
      expect(device.systemConnected, isTrue);
      expect(platform.startScanCalls, 0);
      expect(platform.connectedIds, ['omi-system']);
    },
  );

  test('connect emits connecting then connected snapshot phases', () async {
    platform.systemDevices = [
      BleDevice(
        deviceId: 'omi-system',
        name: 'Omi',
        services: const [_omiService],
      ),
    ];
    final phases = <DeviceConnectionPhase>[];
    final subscription = adapter.snapshots.listen(
      (snapshot) => phases.add(snapshot.phase),
    );

    await adapter.connect('omi-system');
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();

    expect(phases, [
      DeviceConnectionPhase.connecting,
      DeviceConnectionPhase.connected,
    ]);
  });

  test(
    'scan ends in the disconnected phase when nothing is connected',
    () async {
      final phases = <DeviceConnectionPhase>[];
      final subscription = adapter.snapshots.listen(
        (snapshot) => phases.add(snapshot.phase),
      );

      await adapter.scan();
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(phases, [
        DeviceConnectionPhase.scanning,
        DeviceConnectionPhase.disconnected,
      ]);
    },
  );
}

final class _FakeBlePlatform extends UniversalBlePlatform {
  List<BleDevice> systemDevices = const [];
  List<BleDevice> advertisedDevices = const [];
  final List<String> connectedIds = [];
  int startScanCalls = 0;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async =>
      AvailabilityState.poweredOn;

  @override
  Future<bool> enableBluetooth() async => true;

  @override
  Future<bool> disableBluetooth() async => true;

  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    startScanCalls += 1;
    for (final device in advertisedDevices) {
      updateScanResult(device);
    }
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<bool> isScanning() async => false;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
  }) async {
    connectedIds.add(deviceId);
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    updateConnection(deviceId, false);
  }

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async => const [];

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {}

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async => Uint8List.fromList([20]);

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {}

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async => expectedMtu;

  @override
  Future<int> readRssi(String deviceId) async => -40;

  @override
  Future<void> requestConnectionPriority(
    String deviceId,
    BleConnectionPriority priority,
  ) async {}

  @override
  Future<bool> isPaired(String deviceId) async => false;

  @override
  Future<bool> pair(String deviceId) async => true;

  @override
  Future<void> unpair(String deviceId) async {}

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      connectedIds.contains(deviceId)
      ? BleConnectionState.connected
      : BleConnectionState.disconnected;

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async =>
      systemDevices;
}
