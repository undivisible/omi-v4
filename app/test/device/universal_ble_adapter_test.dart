import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/device.dart';
import 'package:universal_ble/universal_ble.dart';

const _omiService = '19b10000-e8f2-537e-4f6c-d104768a1214';
const _audioCodec = '19b10002-e8f2-537e-4f6c-d104768a1214';
const _batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';
const _modelNumber = '00002a24-0000-1000-8000-00805f9b34fb';
const _serialNumber = '00002a25-0000-1000-8000-00805f9b34fb';
const _firmwareRevision = '00002a26-0000-1000-8000-00805f9b34fb';
const _hardwareRevision = '00002a27-0000-1000-8000-00805f9b34fb';
const _manufacturerName = '00002a29-0000-1000-8000-00805f9b34fb';
const _settingsService = '19b10010-e8f2-537e-4f6c-d104768a1214';
const _sleep = '19b10014-e8f2-537e-4f6c-d104768a1214';
const _captureLed = '19b10015-e8f2-537e-4f6c-d104768a1214';
const _rename = '19b10016-e8f2-537e-4f6c-d104768a1214';
const _smpService = '8d53dc1d-1db7-4cd3-868b-8a527460aa84';

final _systemOmi = [
  BleDevice(
    deviceId: 'omi-system',
    name: 'Omi',
    services: const [_omiService],
    isSystemDevice: true,
  ),
];

Uint8List _ascii(String value) => Uint8List.fromList(value.codeUnits);

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

  test('connect reads the Device Information Service metadata', () async {
    platform
      ..systemDevices = _systemOmi
      ..reads.addAll({
        _modelNumber: _ascii('Omi DevKit 2'),
        _firmwareRevision: _ascii('3.0.20'),
        _hardwareRevision: _ascii('Seeed Xiao BLE Sense'),
        _manufacturerName: _ascii('Based Hardware'),
        _batteryLevel: Uint8List.fromList([64]),
        _audioCodec: Uint8List.fromList([21]),
      });

    final device = await adapter.connect('omi-system');

    expect(device.modelNumber, 'Omi DevKit 2');
    expect(device.firmwareRevision, '3.0.20');
    expect(device.hardwareRevision, 'Seeed Xiao BLE Sense');
    expect(device.manufacturerName, 'Based Hardware');
    expect(device.batteryLevel, 64);
    expect(device.audioCodec, DeviceAudioCodec.opusFs320);
  });

  test('connect leaves firmware metadata null when 0x180a is absent', () async {
    platform
      ..systemDevices = _systemOmi
      ..missingCharacteristics.addAll({
        _modelNumber,
        _firmwareRevision,
        _hardwareRevision,
        _manufacturerName,
        _serialNumber,
      });

    final device = await adapter.connect('omi-system');

    expect(device.firmwareRevision, isNull);
    expect(device.hardwareRevision, isNull);
    expect(device.modelNumber, isNull);
    expect(device.manufacturerName, isNull);
  });

  test('battery notifications refresh the connected snapshot', () async {
    platform
      ..systemDevices = _systemOmi
      ..reads[_batteryLevel] = Uint8List.fromList([64]);
    await adapter.connect('omi-system');
    expect(platform.notifiable, contains(_batteryLevel));

    final levels = <int?>[];
    final subscription = adapter.snapshots.listen(
      (snapshot) => levels.add(snapshot.device?.batteryLevel),
    );
    platform.pushNotification('omi-system', _batteryLevel, [41]);
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();

    expect(levels, [41]);
  });

  test('a battery characteristic that cannot notify keeps the read', () async {
    platform
      ..systemDevices = _systemOmi
      ..reads[_batteryLevel] = Uint8List.fromList([64])
      ..missingCharacteristics.add(_batteryLevel);

    final device = await adapter.connect('omi-system');

    expect(device.batteryLevel, isNull);
    expect(platform.notifiable, isNot(contains(_batteryLevel)));
  });

  test('capture LED writes 0x01 on and 0x00 off to 19b10015', () async {
    platform.systemDevices = _systemOmi;
    await adapter.connect('omi-system');

    expect(await adapter.writeCaptureLed(true), isTrue);
    expect(await adapter.writeCaptureLed(false), isTrue);

    expect(
      [
        for (final write in platform.writes)
          if (write.characteristic == _captureLed) write.value,
      ],
      [
        [1],
        [0],
      ],
    );
  });

  test('discovery reports whether the capture LED can be driven', () async {
    platform.systemDevices = _systemOmi;
    await adapter.connect('omi-system');

    expect(adapter.captureLedSupported, isTrue);
  });

  test(
    'firmware without 19b10015 reports the capture LED as undrivable',
    () async {
      platform
        ..systemDevices = _systemOmi
        ..missingCharacteristics.add(_captureLed);
      await adapter.connect('omi-system');

      expect(adapter.captureLedSupported, isFalse);
      expect(await adapter.writeCaptureLed(true), isFalse);
    },
  );

  test('a platform that reports no characteristics stays optimistic until the '
      'first write', () async {
    platform
      ..systemDevices = _systemOmi
      ..gatt = const {}
      ..missingCharacteristics.add(_captureLed);
    await adapter.connect('omi-system');

    expect(adapter.captureLedSupported, isTrue);
    expect(await adapter.writeCaptureLed(true), isFalse);
    expect(adapter.captureLedSupported, isFalse);
  });

  test('reconnecting re-asks whether the capture LED is there', () async {
    platform
      ..systemDevices = _systemOmi
      ..missingCharacteristics.add(_captureLed);
    await adapter.connect('omi-system');
    expect(adapter.captureLedSupported, isFalse);

    platform.missingCharacteristics.remove(_captureLed);
    await adapter.disconnect();
    await adapter.connect('omi-system');

    expect(adapter.captureLedSupported, isTrue);
  });

  test(
    'DFU is offered only when the pendant advertises the SMP service',
    () async {
      platform.systemDevices = _systemOmi;
      await adapter.connect('omi-system');
      expect(adapter.dfuSupported, isFalse);

      await adapter.disconnect();
      platform.gatt = {
        ...platform.gatt,
        _smpService: const ['da2e7828-fbce-4e01-ae9e-261174997c48'],
      };
      await adapter.connect('omi-system');

      expect(adapter.dfuSupported, isTrue);

      await adapter.disconnect();
      expect(adapter.dfuSupported, isFalse);
    },
  );

  test('sleep writes 0x01 to 19b10014', () async {
    platform.systemDevices = _systemOmi;
    await adapter.connect('omi-system');

    expect(await adapter.sleepDevice(), isTrue);
    expect(
      [
        for (final write in platform.writes)
          if (write.characteristic == _sleep) write.value,
      ],
      [
        [1],
      ],
    );
  });

  test('rename writes UTF-8 to 19b10016 and republishes the name', () async {
    platform.systemDevices = _systemOmi;
    await adapter.connect('omi-system');
    final names = <String?>[];
    final subscription = adapter.snapshots.listen(
      (snapshot) => names.add(snapshot.device?.name),
    );

    expect(await adapter.renameDevice('Studio Omi'), isTrue);
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();

    expect(
      platform.writes.where((w) => w.characteristic == _rename).single.value,
      utf8.encode('Studio Omi'),
    );
    expect(names, ['Studio Omi']);
  });

  test('the settings-service writes degrade on older firmware', () async {
    platform
      ..systemDevices = _systemOmi
      ..missingCharacteristics.addAll({_captureLed, _sleep, _rename});
    await adapter.connect('omi-system');

    expect(await adapter.writeCaptureLed(true), isFalse);
    expect(await adapter.sleepDevice(), isFalse);
    expect(await adapter.renameDevice('Studio Omi'), isFalse);
    expect(platform.writes, isEmpty);
  });

  test('the settings-service writes no-op while disconnected', () async {
    expect(await adapter.writeCaptureLed(true), isFalse);
    expect(await adapter.sleepDevice(), isFalse);
    expect(await adapter.renameDevice('Studio Omi'), isFalse);
    expect(platform.writes, isEmpty);
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
  // Characteristics an older pendant firmware does not expose: reads and
  // writes against them fail the way the platform channel would.
  final Set<String> missingCharacteristics = {};
  final Map<String, Uint8List> reads = {};
  final List<({String characteristic, List<int> value})> writes = [];
  final Set<String> notifiable = {};

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

  // The GATT table discovery reports, minus anything in
  // [missingCharacteristics]. An empty map stands in for a platform that
  // reports no characteristics at all.
  Map<String, List<String>> gatt = {
    _omiService: [_audioCodec],
    _settingsService: [_sleep, _captureLed, _rename],
  };

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async => [
    for (final service in gatt.entries)
      BleService(service.key, [
        for (final characteristic in service.value)
          if (!missingCharacteristics.contains(characteristic))
            BleCharacteristic(characteristic, const [], const []),
      ]),
  ];

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {
    if (missingCharacteristics.contains(characteristic)) {
      throw StateError('characteristic $characteristic not found');
    }
    notifiable.add(characteristic);
  }

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async {
    if (missingCharacteristics.contains(characteristic)) {
      throw StateError('characteristic $characteristic not found');
    }
    return reads[characteristic] ?? Uint8List.fromList([20]);
  }

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {
    if (missingCharacteristics.contains(characteristic)) {
      throw StateError('characteristic $characteristic not found');
    }
    writes.add((characteristic: characteristic, value: value.toList()));
  }

  void pushNotification(String deviceId, String characteristic, List<int> v) =>
      updateCharacteristicValue(
        deviceId,
        characteristic,
        Uint8List.fromList(v),
        null,
      );

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
