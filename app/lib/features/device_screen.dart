import 'package:flutter/material.dart';

import '../device/device.dart';
import '../ui/omi_ui.dart';

class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});

  static const devices = [
    RelayDevice(id: 'desktop', name: 'This computer'),
    RelayDevice(id: 'wearable', name: 'Omi wearable'),
    RelayDevice(id: 'phone', name: 'Phone relay'),
  ];

  @override
  Widget build(BuildContext context) {
    return PageList(
      title: 'Devices',
      subtitle: 'Capture and control stay visible across every surface.',
      children: [
        _DeviceTile(
          icon: Icons.laptop_mac_rounded,
          device: devices[0],
          detail: 'Screen and microphone ready',
          connected: true,
        ),
        _DeviceTile(
          icon: Icons.watch_outlined,
          device: devices[1],
          detail: 'Not connected',
        ),
        _DeviceTile(
          icon: Icons.phone_iphone_rounded,
          device: devices[2],
          detail: 'Waiting for pairing',
        ),
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.icon,
    required this.device,
    required this.detail,
    this.connected = false,
  });

  final IconData icon;
  final RelayDevice device;
  final String detail;
  final bool connected;

  @override
  Widget build(BuildContext context) => BaseTile(
    icon: icon,
    title: device.name,
    detail: detail,
    trailing: Icon(
      connected ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded,
      color: connected ? const Color(0xff73d5c4) : null,
    ),
  );
}
