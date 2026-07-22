import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'device_relay.dart';
import 'device_models.dart';

final class UniversalBleDeviceRelayAdapter
    implements DeviceRelayAdapter, DeviceRelayHaptics {
  static const _omiService = '19b10000-e8f2-537e-4f6c-d104768a1214';
  static const _audioStream = '19b10001-e8f2-537e-4f6c-d104768a1214';
  static const _audioCodec = '19b10002-e8f2-537e-4f6c-d104768a1214';
  static const _batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const _batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';
  static const _speakerService = 'cab1ab95-2ea5-4f4d-bb56-874b72cfc984';
  static const _speakerHaptic = 'cab1ab96-2ea5-4f4d-bb56-874b72cfc984';

  final _snapshots = StreamController<DeviceRelaySnapshot>.broadcast();
  final _connectionStates = StreamController<bool>.broadcast();
  final Map<String, BleDevice> _devices = {};
  String? _connectedId;
  RelayDevice? _connectedDevice;
  StreamSubscription<bool>? _connectionSubscription;
  bool _connected = false;
  bool _restoringNotifications = false;
  Timer? _restoreRetryTimer;
  int _restoreAttempts = 0;

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

    final connectedBleDevice = _connectedId == null
        ? null
        : _devices[_connectedId];
    _devices.clear();
    if (connectedBleDevice != null) {
      _devices[connectedBleDevice.deviceId] = connectedBleDevice;
    }
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
        phase: _connectedDevice == null
            ? DeviceConnectionPhase.disconnected
            : _connected
            ? DeviceConnectionPhase.connected
            : DeviceConnectionPhase.connecting,
        capabilities: capabilities,
        device: _connectedDevice,
      ),
    );
    return _devices.values.map(_relayDevice).toList(growable: false);
  }

  @override
  Future<RelayDevice> connect(String deviceId) async {
    if (_connectedId == deviceId && _connectedDevice != null && _connected) {
      return _connectedDevice!;
    }
    if (_connectedId != null) await disconnect();
    _restoreAttempts = 0;
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
      await UniversalBle.connect(deviceId, autoConnect: true);
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
      _connectedDevice = connected;
      _connected = true;
      await _connectionSubscription?.cancel();
      _connectionSubscription = UniversalBle.connectionStream(deviceId).listen(
        (connected) {
          if (connected) {
            unawaited(_restoreNotifications(deviceId));
          } else {
            _connected = false;
            _restoreRetryTimer?.cancel();
            _restoreRetryTimer = null;
            _restoreAttempts = 0;
            _connectionStates.add(false);
            _snapshots.add(
              DeviceRelaySnapshot(
                phase: DeviceConnectionPhase.connecting,
                capabilities: capabilities,
                device: _connectedDevice,
                message: 'Reconnecting…',
              ),
            );
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          _connected = false;
          _connectionStates.addError(error, stackTrace);
          _snapshots.add(
            DeviceRelaySnapshot(
              phase: DeviceConnectionPhase.failed,
              capabilities: capabilities,
              device: _connectedDevice,
              message: '$error',
            ),
          );
        },
      );
      _snapshots.add(
        DeviceRelaySnapshot(
          phase: DeviceConnectionPhase.connected,
          capabilities: capabilities,
          device: connected,
        ),
      );
      return connected;
    } catch (error) {
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;
      await UniversalBle.disconnect(deviceId);
      _connectedId = null;
      _connectedDevice = null;
      _connected = false;
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
  Future<bool> sendHaptic(int level) async {
    final deviceId = _connectedId;
    if (deviceId == null || !_connected) return false;
    try {
      await UniversalBle.write(
        deviceId,
        _speakerService,
        _speakerHaptic,
        Uint8List.fromList([level & 0xff]),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    final deviceId = _connectedId;
    if (deviceId == null) return;
    _connectedId = null;
    _connectedDevice = null;
    _connected = false;
    _restoreRetryTimer?.cancel();
    _restoreRetryTimer = null;
    _restoreAttempts = 0;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    try {
      await UniversalBle.unsubscribe(deviceId, _omiService, _audioStream);
    } catch (_) {}
    await UniversalBle.disconnect(deviceId);
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

  @override
  Stream<bool> connectionState(String deviceId) => _connectionStates.stream;

  Future<void> _restoreNotifications(String deviceId) async {
    if (_connectedId != deviceId || _restoringNotifications) return;
    _restoringNotifications = true;
    try {
      await UniversalBle.discoverServices(deviceId);
      await UniversalBle.subscribeNotifications(
        deviceId,
        _omiService,
        _audioStream,
      );
      if (_connectedId == deviceId) {
        _restoreRetryTimer?.cancel();
        _restoreRetryTimer = null;
        _restoreAttempts = 0;
        _connected = true;
        _connectionStates.add(true);
        _snapshots.add(
          DeviceRelaySnapshot(
            phase: DeviceConnectionPhase.connected,
            capabilities: capabilities,
            device: _connectedDevice,
          ),
        );
      }
    } catch (error) {
      if (_connectedId == deviceId) {
        _restoreAttempts += 1;
        if (_restoreAttempts < 3) {
          _restoreRetryTimer?.cancel();
          _restoreRetryTimer = Timer(
            const Duration(seconds: 1),
            () => unawaited(_restoreNotifications(deviceId)),
          );
        }
        _snapshots.add(
          DeviceRelaySnapshot(
            phase: _restoreAttempts < 3
                ? DeviceConnectionPhase.connecting
                : DeviceConnectionPhase.failed,
            capabilities: capabilities,
            device: _connectedDevice,
            message: '$error',
          ),
        );
      }
    } finally {
      _restoringNotifications = false;
    }
  }

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
