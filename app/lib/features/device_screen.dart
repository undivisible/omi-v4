import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../device/device.dart';
import '../ui/omi_ui.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({this.previewMode = false, super.key});

  final bool previewMode;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  late final DeviceRelayService relay = DeviceRelayService(
    role: _mobile
        ? DeviceRelayRole.mobileOwner
        : DeviceRelayRole.desktopObserver,
    adapter: _mobile
        ? UniversalBleDeviceRelayAdapter()
        : const UnavailableDeviceRelayAdapter(
            state: DeviceCapabilityState.unsupported,
          ),
  );
  List<RelayDevice> devices = const [];
  DeviceRelaySnapshot? snapshot;
  Object? error;
  late final StreamSubscription<DeviceRelaySnapshot> _snapshotSubscription;

  bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _snapshotSubscription = relay.snapshots.listen((next) {
      if (mounted) setState(() => snapshot = next);
    });
  }

  @override
  void dispose() {
    unawaited(_snapshotSubscription.cancel());
    if (_mobile) unawaited(relay.disconnect().onError((_, _) {}));
    super.dispose();
  }

  Future<void> scan() async {
    setState(() => error = null);
    try {
      final found = await relay.scan();
      if (mounted) setState(() => devices = found);
    } catch (next) {
      if (mounted) setState(() => error = next);
    }
  }

  Future<void> connect(RelayDevice device) async {
    setState(() => error = null);
    try {
      await relay.connect(device.id);
    } catch (next) {
      if (mounted) setState(() => error = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = snapshot?.phase ?? DeviceConnectionPhase.disconnected;
    return PageList(
      title: 'Devices',
      subtitle: _mobile
          ? 'This phone relays audio from your Omi wearable.'
          : 'Pair and stream Omi hardware from the mobile companion.',
      children: [
        if (widget.previewMode)
          const BaseTile(
            icon: Icons.visibility_outlined,
            title: 'Device controls unavailable in preview',
            detail: 'Bluetooth scanning and connection are disabled.',
            trailing: Icon(Icons.block_rounded),
          )
        else if (_mobile)
          BaseTile(
            icon: Icons.bluetooth_searching_rounded,
            title: phase == DeviceConnectionPhase.scanning
                ? 'Scanning nearby…'
                : 'Find an Omi device',
            detail: error == null
                ? 'Bluetooth permission is requested when you scan.'
                : '$error',
            trailing: IconButton(
              tooltip: 'Scan',
              onPressed: phase == DeviceConnectionPhase.scanning ? null : scan,
              icon: const Icon(Icons.refresh_rounded),
            ),
          )
        else
          const BaseTile(
            icon: Icons.phone_iphone_rounded,
            title: 'Mobile relay required',
            detail:
                'Device pairing is intentionally unavailable on this client.',
            trailing: Icon(Icons.info_outline_rounded),
          ),
        for (final device in devices)
          BaseTile(
            icon: Icons.watch_outlined,
            title: device.name,
            detail: [
              if (device.signalStrength case final signal?) '$signal dBm',
              if (device.batteryLevel case final battery?) '$battery% battery',
            ].join(' · '),
            trailing: IconButton(
              tooltip: 'Connect',
              onPressed: phase == DeviceConnectionPhase.connecting
                  ? null
                  : () => connect(device),
              icon: Icon(
                snapshot?.device?.id == device.id &&
                        phase == DeviceConnectionPhase.connected
                    ? Icons.check_circle_rounded
                    : Icons.add_circle_outline_rounded,
              ),
            ),
          ),
      ],
    );
  }
}
