import 'package:flutter/material.dart';

import '../device/device.dart';

class WifiDebugPanel extends StatefulWidget {
  const WifiDebugPanel({super.key, required this.relay});

  final DeviceRelayService relay;

  @override
  State<WifiDebugPanel> createState() => _WifiDebugPanelState();
}

class _WifiDebugPanelState extends State<WifiDebugPanel> {
  final _ssid = TextEditingController();
  final _password = TextEditingController();
  bool _home = false;
  bool _busy = false;
  String? _result;

  @override
  void dispose() {
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<int> Function() command) async {
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final code = await command();
      if (mounted) setState(() => _result = wifiResultMessage(code));
    } on FormatException catch (error) {
      if (mounted) setState(() => _result = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = widget.relay.wifiSupported;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            supported ? Icons.wifi : Icons.wifi_off,
            color: supported
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
          ),
          title: Text(supported ? 'Wi-Fi ready' : 'Wi-Fi unavailable'),
          subtitle: Text(
            supported
                ? 'Configure the pendant and start a manual sync.'
                : 'Connect a Wi-Fi-capable pendant to use these controls.',
          ),
        ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Device hotspot')),
            ButtonSegment(value: true, label: Text('Home network')),
          ],
          selected: {_home},
          onSelectionChanged: _busy
              ? null
              : (selection) => setState(() => _home = selection.single),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ssid,
          enabled: supported && !_busy,
          decoration: const InputDecoration(labelText: 'Wi-Fi name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          enabled: supported && !_busy,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: supported && !_busy
              ? () => _run(
                  () => widget.relay.configureWifi(
                    _ssid.text,
                    _password.text,
                    home: _home,
                  ),
                )
              : null,
          child: const Text('Save Wi-Fi setup'),
        ),
        if (!_home) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: supported && !_busy
                ? () => _run(widget.relay.startWifiSync)
                : null,
            child: const Text('Start manual sync'),
          ),
          TextButton(
            onPressed: supported && !_busy
                ? () => _run(widget.relay.stopWifiSync)
                : null,
            child: const Text('Stop Wi-Fi sync'),
          ),
        ] else ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: supported && !_busy
                ? () => _run(widget.relay.clearHomeWifi)
                : null,
            child: const Text('Forget home network'),
          ),
        ],
        if (_busy) const LinearProgressIndicator(),
        if (_result != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_result!),
            ),
          ),
      ],
    );
  }
}
