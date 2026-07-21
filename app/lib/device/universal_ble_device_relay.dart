import 'dart:async';

import 'package:universal_ble/universal_ble.dart';

import 'device_relay.dart';
import 'device_models.dart';

final class UniversalBleDeviceRelayAdapter implements DeviceRelayAdapter {
  static const _omiService = '19b10000-e8f2-537e-4f6c-d104768a1214';
  static const _audioStream = '19b10001-e8f2-537e-4f6c-d104768a1214';
  static const _audioCodec = '19b10002-e8f2-537e-4f6c-d104768a1214';
  static const _batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const _batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';

  final _snapshots = StreamController<DeviceRelaySnapshot>.broadcast();
  final Map<String, BleDevice> _devices = {};
  String? _connectedId;

  @override
  DeviceRelayCapabilities get capabilities => const DeviceRelayCapabilities(
    pairing: DeviceCapabilityState.available,
    metadata: DeviceCapabilityState.available,
    audioStreaming: DeviceCapabilityState.available,
  );

  @override
  Stream<DeviceRelaySnapshot> get snapshots => _snapshots.stream;

  @override
  Future<List<RelayDevice>> scan() async {
    if (!await UniversalBle.hasPermissions()) {
      try {
        await UniversalBle.requestPermissions();
      } catch (_) {
        _emitUnavailable(DeviceCapabilityState.permissionRequired);
        throw const DeviceRelayUnavailable(
          'scan',
          DeviceCapabilityState.permissionRequired,
        );
      }
    }
    final availability = await UniversalBle.getBluetoothAvailabilityState();
    if (availability != AvailabilityState.poweredOn) {
      _emitUnavailable(DeviceCapabilityState.adapterUnavailable);
      throw const DeviceRelayUnavailable(
        'scan',
        DeviceCapabilityState.adapterUnavailable,
      );
    }

    _devices.clear();
    _snapshots.add(
      DeviceRelaySnapshot(
        phase: DeviceConnectionPhase.scanning,
        capabilities: capabilities,
      ),
    );
    final subscription = UniversalBle.scanStream.listen((device) {
      if (device.services.any(
        (service) => service.toLowerCase() == _omiService,
      )) {
        _devices[device.deviceId] = device;
      }
    });
    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: const [_omiService]),
      );
      await Future<void>.delayed(const Duration(seconds: 5));
    } finally {
      await UniversalBle.stopScan();
      await subscription.cancel();
    }
    _snapshots.add(
      DeviceRelaySnapshot(
        phase: DeviceConnectionPhase.disconnected,
        capabilities: capabilities,
      ),
    );
    return _devices.values.map(_relayDevice).toList(growable: false);
  }

  @override
  Future<RelayDevice> connect(String deviceId) async {
    final device = _devices[deviceId];
    if (device == null) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Scan before connecting');
    }
    _snapshots.add(
      DeviceRelaySnapshot(
        phase: DeviceConnectionPhase.connecting,
        capabilities: capabilities,
        device: _relayDevice(device),
      ),
    );
    try {
      await UniversalBle.connect(deviceId);
      _connectedId = deviceId;
      await UniversalBle.discoverServices(deviceId);
      final codec = await _readFirst(deviceId, _omiService, _audioCodec);
      final battery = await _readFirst(
        deviceId,
        _batteryService,
        _batteryLevel,
      );
      await UniversalBle.subscribeNotifications(
        deviceId,
        _omiService,
        _audioStream,
      );
      final connected = _relayDevice(device, codec: codec, battery: battery);
      _snapshots.add(
        DeviceRelaySnapshot(
          phase: DeviceConnectionPhase.connected,
          capabilities: capabilities,
          device: connected,
        ),
      );
      return connected;
    } catch (error) {
      await UniversalBle.disconnect(deviceId);
      _connectedId = null;
      _snapshots.add(
        DeviceRelaySnapshot(
          phase: DeviceConnectionPhase.failed,
          capabilities: capabilities,
          device: _relayDevice(device),
          message: '$error',
        ),
      );
      rethrow;
    }
  }

  Future<int?> _readFirst(
    String deviceId,
    String service,
    String characteristic,
  ) async {
    try {
      final value = await UniversalBle.read(deviceId, service, characteristic);
      return value.isEmpty ? null : value.first;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> disconnect() async {
    final deviceId = _connectedId;
    if (deviceId == null) return;
    try {
      await UniversalBle.unsubscribe(deviceId, _omiService, _audioStream);
    } finally {
      await UniversalBle.disconnect(deviceId);
    }
    _connectedId = null;
    _snapshots.add(
      DeviceRelaySnapshot(
        phase: DeviceConnectionPhase.disconnected,
        capabilities: capabilities,
      ),
    );
  }

  @override
  Stream<List<int>> audioPackets(String deviceId) =>
      UniversalBle.characteristicValueStream(
        deviceId,
        _audioStream,
      ).map((value) => value.toList(growable: false));

  RelayDevice _relayDevice(BleDevice device, {int? codec, int? battery}) =>
      RelayDevice(
        id: device.deviceId,
        name: device.name?.isNotEmpty == true ? device.name! : 'Omi',
        signalStrength: device.rssi,
        batteryLevel: battery,
        audioCodec: codec == null
            ? DeviceAudioCodec.unknown
            : DeviceAudioCodec.fromFirmwareId(codec),
      );

  void _emitUnavailable(DeviceCapabilityState state) {
    final unavailable = DeviceRelayCapabilities.unavailable(state);
    _snapshots.add(
      DeviceRelaySnapshot(
        phase: DeviceConnectionPhase.unavailable,
        capabilities: unavailable,
        message: state.name,
      ),
    );
  }
}
