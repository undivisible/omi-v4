import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'device_relay.dart';
import 'device_models.dart';

final class UniversalBleDeviceRelayAdapter
    implements
        DeviceRelayAdapter,
        DeviceRelayHaptics,
        DeviceRelayLed,
        DeviceRelaySleep,
        DeviceRelayRename {
  UniversalBleDeviceRelayAdapter({
    this.scanSettle = const Duration(seconds: 5),
  });

  static const _omiService = '19b10000-e8f2-537e-4f6c-d104768a1214';
  static const _audioStream = '19b10001-e8f2-537e-4f6c-d104768a1214';
  static const _audioCodec = '19b10002-e8f2-537e-4f6c-d104768a1214';
  static const _batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const _batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';
  static const _speakerService = 'cab1ab95-2ea5-4f4d-bb56-874b72cfc984';
  static const _speakerHaptic = 'cab1ab96-2ea5-4f4d-bb56-874b72cfc984';
  // Device Information Service (0000180a) developer metadata. Read once on
  // connect, mirroring the upstream firmware's getDeviceInfo() reads.
  static const _deviceInfoService = '0000180a-0000-1000-8000-00805f9b34fb';
  static const _modelNumber = '00002a24-0000-1000-8000-00805f9b34fb';
  static const _firmwareRevision = '00002a26-0000-1000-8000-00805f9b34fb';
  static const _hardwareRevision = '00002a27-0000-1000-8000-00805f9b34fb';
  static const _manufacturerName = '00002a29-0000-1000-8000-00805f9b34fb';
  static const _serialNumber = '00002a25-0000-1000-8000-00805f9b34fb';
  // Settings service (19b10010) hosts the firmware's app-writable control
  // characteristics. Guarded reads/writes degrade gracefully on older firmware
  // that predates these characteristics.
  static const _settingsService = '19b10010-e8f2-537e-4f6c-d104768a1214';
  // App-commanded sleep/power-off. Write-only, 1 byte: 0x01 triggers sleep.
  static const _sleepCharacteristic = '19b10014-e8f2-537e-4f6c-d104768a1214';
  // Capture-state LED. Read/write, 1 byte: 0x00 = idle (red), 0x01 = capturing
  // (blue). Explicit override that stays consistent with firmware's own
  // audio-subscription-driven capture state.
  static const _captureLedCharacteristic =
      '19b10015-e8f2-537e-4f6c-d104768a1214';
  // Device rename. Read/write UTF-8 string; firmware persists to NVS and
  // re-applies on boot. GAP Device Name (0x2a00) stays read-only.
  static const _renameCharacteristic = '19b10016-e8f2-537e-4f6c-d104768a1214';

  final Duration scanSettle;
  final _snapshots = StreamController<DeviceRelaySnapshot>.broadcast();
  final _connectionStates = StreamController<bool>.broadcast();
  final Map<String, BleDevice> _devices = {};
  final Set<String> _systemDeviceIds = {};
  String? _connectedId;
  RelayDevice? _connectedDevice;
  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription<List<int>>? _batterySubscription;
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
    _systemDeviceIds.removeWhere((id) => id != _connectedId);
    if (connectedBleDevice != null) {
      _devices[connectedBleDevice.deviceId] = connectedBleDevice;
    }
    _snapshots.add(
      DeviceRelaySnapshot(
        phase: DeviceConnectionPhase.scanning,
        capabilities: capabilities,
      ),
    );
    // A pendant that is already BLE-connected to the system (or to this app
    // from a previous session) stops advertising, so a scan alone would never
    // find it. Fold system-connected peripherals exposing the Omi service
    // into the results before scanning for advertising ones.
    _mergeSystemDevices(await _systemConnectedDevices());
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
      await Future<void>.delayed(scanSettle);
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

  // Transient BLE connect failures (e.g. Android GATT status 133, or a
  // connect racing shortly after scan/discovery on iOS) are common and
  // usually self-heal on a short retry. Retry the whole connect+discover+
  // subscribe sequence up to _maxConnectRetries times with backoff before
  // surfacing a terminal failure.
  static const _maxConnectRetries = 2;
  static const _connectRetryDelays = [
    Duration(milliseconds: 400),
    Duration(milliseconds: 1000),
  ];

  @override
  Future<RelayDevice> connect(String deviceId) async {
    if (_connectedId == deviceId && _connectedDevice != null && _connected) {
      // Re-emit so a UI that missed the original connect snapshot (or whose
      // reconnect button was pressed while already connected) refreshes.
      _snapshots.add(
        DeviceRelaySnapshot(
          phase: DeviceConnectionPhase.connected,
          capabilities: capabilities,
          device: _connectedDevice,
        ),
      );
      return _connectedDevice!;
    }
    if (_connectedId != null) await disconnect();
    _restoreAttempts = 0;
    var device = _devices[deviceId];
    if (device == null) {
      // The remembered pendant may already be connected at the system level
      // (it stops advertising in that state); attaching to a system-connected
      // device is valid, so check there before falling back to a scan.
      _mergeSystemDevices(await _systemConnectedDevices());
      device = _devices[deviceId];
    }
    if (device == null) {
      // Reconnecting a remembered device after an app restart: the scan
      // cache is empty, so scan on demand instead of failing.
      await scan();
      device = _devices[deviceId];
    }
    if (device == null) {
      throw StateError(
        'Your Omi was not found nearby. Make sure it is charged and close '
        'by, then try again.',
      );
    }

    Object? lastError;
    for (var attempt = 0; attempt <= _maxConnectRetries; attempt++) {
      if (attempt > 0) {
        // Disconnect-before-reconnect: make sure the stack is in a clean
        // state before retrying, otherwise a half-open connection can make
        // the next attempt fail immediately too.
        try {
          await UniversalBle.disconnect(deviceId);
        } catch (_) {}
        // ignore: avoid_print
        print(
          'UniversalBleDeviceRelayAdapter: connect attempt $attempt for '
          '$deviceId after error: $lastError',
        );
        await Future<void>.delayed(_connectRetryDelays[attempt - 1]);
      }
      _snapshots.add(
        DeviceRelaySnapshot(
          phase: DeviceConnectionPhase.connecting,
          capabilities: capabilities,
          device: _relayDevice(device),
          message: attempt > 0 ? 'Retrying connection…' : null,
        ),
      );
      try {
        return await _attemptConnect(deviceId, device);
      } catch (error) {
        lastError = error;
        // ignore: avoid_print
        print(
          'UniversalBleDeviceRelayAdapter: connect failed for $deviceId '
          '(attempt $attempt): $error',
        );
        if (attempt == _maxConnectRetries) {
          _snapshots.add(
            DeviceRelaySnapshot(
              phase: DeviceConnectionPhase.failed,
              capabilities: capabilities,
              device: _relayDevice(device),
              message:
                  'Could not connect to ${device.name?.isNotEmpty == true ? device.name : 'the device'} '
                  'after ${_maxConnectRetries + 1} attempts. Move closer, '
                  'make sure the device is charged, and try again.',
            ),
          );
        }
      }
    }
    throw lastError ?? StateError('connect failed');
  }

  Future<RelayDevice> _attemptConnect(String deviceId, BleDevice device) async {
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
      final info = await _readDeviceInfo(deviceId);
      await UniversalBle.subscribeNotifications(
        deviceId,
        _omiService,
        _audioStream,
      );
      final connected = _relayDevice(
        device,
        codec: codec,
        battery: battery,
        info: info,
      );
      _connectedDevice = connected;
      _connected = true;
      await _subscribeBattery(deviceId);
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
      try {
        await UniversalBle.disconnect(deviceId);
      } catch (_) {}
      _connectedId = null;
      _connectedDevice = null;
      _connected = false;
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

  Future<String?> _readString(
    String deviceId,
    String service,
    String characteristic,
  ) async {
    try {
      final value = await UniversalBle.read(deviceId, service, characteristic);
      if (value.isEmpty) return null;
      final text = String.fromCharCodes(value).trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  Future<_DeviceInfo> _readDeviceInfo(String deviceId) async => _DeviceInfo(
    modelNumber: await _readString(deviceId, _deviceInfoService, _modelNumber),
    firmwareRevision: await _readString(
      deviceId,
      _deviceInfoService,
      _firmwareRevision,
    ),
    hardwareRevision: await _readString(
      deviceId,
      _deviceInfoService,
      _hardwareRevision,
    ),
    manufacturerName: await _readString(
      deviceId,
      _deviceInfoService,
      _manufacturerName,
    ),
    serialNumber: await _readString(
      deviceId,
      _deviceInfoService,
      _serialNumber,
    ),
  );

  // Prefer a live battery notification over the one-shot read so the reported
  // level follows the pendant as it drains and charges. Firmware that does not
  // push notifications simply never fires the stream, leaving the initial read.
  Future<void> _subscribeBattery(String deviceId) async {
    await _batterySubscription?.cancel();
    _batterySubscription = null;
    try {
      await UniversalBle.subscribeNotifications(
        deviceId,
        _batteryService,
        _batteryLevel,
      );
    } catch (_) {
      return;
    }
    _batterySubscription =
        UniversalBle.characteristicValueStream(deviceId, _batteryLevel).listen((
          value,
        ) {
          if (value.isEmpty || _connectedId != deviceId) return;
          final level = value.first;
          final device = _connectedDevice;
          if (device == null || device.batteryLevel == level) return;
          _connectedDevice = device.copyWith(batteryLevel: level);
          if (_connected) {
            _snapshots.add(
              DeviceRelaySnapshot(
                phase: DeviceConnectionPhase.connected,
                capabilities: capabilities,
                device: _connectedDevice,
              ),
            );
          }
        }, onError: (Object _) {});
  }

  @override
  Future<bool> writeCaptureLed(bool capturing) async {
    final deviceId = _connectedId;
    if (deviceId == null || !_connected) return false;
    final payload = Uint8List.fromList([capturing ? 1 : 0]);
    try {
      await UniversalBle.write(
        deviceId,
        _settingsService,
        _captureLedCharacteristic,
        payload,
      );
      return true;
    } catch (_) {
      try {
        await UniversalBle.write(
          deviceId,
          _settingsService,
          _captureLedCharacteristic,
          payload,
          withoutResponse: true,
        );
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  @override
  Future<bool> sleepDevice() async {
    final deviceId = _connectedId;
    if (deviceId == null || !_connected) return false;
    final payload = Uint8List.fromList([1]);
    try {
      await UniversalBle.write(
        deviceId,
        _settingsService,
        _sleepCharacteristic,
        payload,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> renameDevice(String name) async {
    final deviceId = _connectedId;
    if (deviceId == null || !_connected) return false;
    final payload = Uint8List.fromList(utf8.encode(name));
    try {
      await UniversalBle.write(
        deviceId,
        _settingsService,
        _renameCharacteristic,
        payload,
      );
      final device = _connectedDevice;
      if (device != null) {
        _connectedDevice = device.copyWith(name: name);
        _snapshots.add(
          DeviceRelaySnapshot(
            phase: DeviceConnectionPhase.connected,
            capabilities: capabilities,
            device: _connectedDevice,
          ),
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> sendHaptic(int level) async {
    final deviceId = _connectedId;
    if (deviceId == null || !_connected) return false;
    final payload = Uint8List.fromList([level & 0xff]);
    try {
      await UniversalBle.write(
        deviceId,
        _speakerService,
        _speakerHaptic,
        payload,
      );
      return true;
    } catch (_) {
      // Some firmware revisions expose the haptic characteristic as
      // write-without-response only; retry in that mode before giving up.
      try {
        await UniversalBle.write(
          deviceId,
          _speakerService,
          _speakerHaptic,
          payload,
          withoutResponse: true,
        );
        return true;
      } catch (_) {
        return false;
      }
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
    await _batterySubscription?.cancel();
    _batterySubscription = null;
    try {
      await UniversalBle.unsubscribe(deviceId, _omiService, _audioStream);
    } catch (_) {}
    try {
      await UniversalBle.unsubscribe(deviceId, _batteryService, _batteryLevel);
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

  Future<List<BleDevice>> _systemConnectedDevices() async {
    try {
      return await UniversalBle.getSystemDevices(
        withServices: const [_omiService],
      );
    } catch (_) {
      return const [];
    }
  }

  void _mergeSystemDevices(List<BleDevice> systemDevices) {
    for (final device in systemDevices) {
      _devices[device.deviceId] = device;
      _systemDeviceIds.add(device.deviceId);
    }
  }

  RelayDevice _relayDevice(
    BleDevice device, {
    int? codec,
    int? battery,
    _DeviceInfo? info,
  }) => RelayDevice(
    id: device.deviceId,
    name: device.name?.isNotEmpty == true ? device.name! : 'Omi',
    signalStrength: device.rssi,
    batteryLevel: battery,
    modelNumber: info?.modelNumber,
    firmwareRevision: info?.firmwareRevision,
    hardwareRevision: info?.hardwareRevision,
    manufacturerName: info?.manufacturerName,
    serialNumber: info?.serialNumber,
    audioCodec: codec == null
        ? DeviceAudioCodec.unknown
        : DeviceAudioCodec.fromFirmwareId(codec),
    systemConnected:
        device.isSystemDevice == true ||
        _systemDeviceIds.contains(device.deviceId),
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

class _DeviceInfo {
  const _DeviceInfo({
    this.modelNumber,
    this.firmwareRevision,
    this.hardwareRevision,
    this.manufacturerName,
    this.serialNumber,
  });

  final String? modelNumber;
  final String? firmwareRevision;
  final String? hardwareRevision;
  final String? manufacturerName;
  final String? serialNumber;
}
