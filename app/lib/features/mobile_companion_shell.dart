import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_services.dart';
import '../device/device.dart';
import '../native/native_hub.dart';
import '../providers/providers.dart';
import '../ui/omi_ui.dart';

class MobileCompanionShell extends StatefulWidget {
  const MobileCompanionShell({
    required this.services,
    this.pairedDevices,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final PairedDeviceStore? pairedDevices;
  final bool previewMode;

  @override
  State<MobileCompanionShell> createState() => _MobileCompanionShellState();
}

class _MobileCompanionShellState extends State<MobileCompanionShell> {
  static const _maxTranscripts = 100;

  late final PairedDeviceStore _pairedDevices =
      widget.pairedDevices ?? PreferencesPairedDeviceStore();
  final List<TranscriptDelta> _transcripts = [];
  StreamSubscription<NativeEvent>? _nativeEventSubscription;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _nativeEventSubscription = widget.services.nativeEvents.listen((event) {
      if (event case NativeEventTranscriptDelta(:final value)
          when value.finalSegment) {
        if (!mounted) return;
        setState(() {
          _transcripts.insert(0, value);
          if (_transcripts.length > _maxTranscripts) {
            _transcripts.removeRange(_maxTranscripts, _transcripts.length);
          }
        });
      }
    }, onError: (Object error, StackTrace stackTrace) {});
  }

  @override
  void dispose() {
    unawaited(_nativeEventSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (_tab) {
      0 => MobileDeviceHome(
        services: widget.services,
        pairedDevices: _pairedDevices,
        previewMode: widget.previewMode,
      ),
      1 => MobileCaptureScreen(
        services: widget.services,
        transcripts: _transcripts,
      ),
      _ => MobileSettingsScreen(
        services: widget.services,
        previewMode: widget.previewMode,
      ),
    };
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 8),
            child: body,
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            key: Key('companion_tab_device'),
            icon: Icon(Icons.watch_outlined),
            label: 'Device',
          ),
          NavigationDestination(
            key: Key('companion_tab_capture'),
            icon: Icon(Icons.graphic_eq_rounded),
            label: 'Capture',
          ),
          NavigationDestination(
            key: Key('companion_tab_settings'),
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class MobileDeviceHome extends StatefulWidget {
  const MobileDeviceHome({
    required this.services,
    required this.pairedDevices,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final PairedDeviceStore pairedDevices;
  final bool previewMode;

  @override
  State<MobileDeviceHome> createState() => MobileDeviceHomeState();
}

class MobileDeviceHomeState extends State<MobileDeviceHome> {
  static const desktopNoticeKey = 'desktop_install_notice_dismissed_v1';

  late final DeviceRelayService relay = widget.services.deviceRelay;
  List<RelayDevice> devices = const [];
  DeviceRelaySnapshot? snapshot;
  Object? error;
  String? rememberedDeviceId;
  bool _reconnectAttempted = false;
  bool? _desktopNoticeDismissed;
  StreamSubscription<DeviceRelaySnapshot>? _snapshotSubscription;

  bool get _mobile => relay.role == DeviceRelayRole.mobileOwner;

  DeviceConnectionPhase get _phase =>
      snapshot?.phase ?? DeviceConnectionPhase.disconnected;

  RelayDevice? get _connectedDevice =>
      _phase == DeviceConnectionPhase.connected ? snapshot?.device : null;

  @override
  void initState() {
    super.initState();
    _snapshotSubscription = relay.snapshots.listen((next) {
      if (mounted) setState(() => snapshot = next);
    });
    if (!widget.previewMode && _mobile) unawaited(_restorePairing());
    unawaited(_loadDesktopNotice());
  }

  Future<void> _loadDesktopNotice() async {
    bool dismissed;
    try {
      dismissed =
          (await SharedPreferences.getInstance()).getBool(desktopNoticeKey) ??
          false;
    } catch (_) {
      dismissed = false;
    }
    if (mounted) setState(() => _desktopNoticeDismissed = dismissed);
  }

  Future<void> _dismissDesktopNotice() async {
    setState(() => _desktopNoticeDismissed = true);
    try {
      await (await SharedPreferences.getInstance()).setBool(
        desktopNoticeKey,
        true,
      );
    } catch (_) {}
  }

  Future<void> _restorePairing() async {
    String? remembered;
    try {
      remembered = await widget.pairedDevices.read();
    } catch (_) {
      remembered = null;
    }
    if (!mounted || remembered == null) return;
    setState(() => rememberedDeviceId = remembered);
    if (_reconnectAttempted ||
        _phase != DeviceConnectionPhase.disconnected ||
        !widget.services.productionReady) {
      return;
    }
    _reconnectAttempted = true;
    try {
      await widget.services.connectDevice(remembered);
    } catch (next) {
      if (mounted) setState(() => error = next);
    }
  }

  @override
  void dispose() {
    unawaited(_snapshotSubscription?.cancel());
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
      await widget.services.connectDevice(device.id);
      await widget.pairedDevices.save(device.id);
      if (mounted) setState(() => rememberedDeviceId = device.id);
    } catch (next) {
      if (mounted) setState(() => error = next);
    }
  }

  Future<void> disconnect() async {
    setState(() => error = null);
    try {
      await widget.services.disconnectDevice();
      if (mounted) setState(() {});
    } catch (next) {
      if (mounted) setState(() => error = next);
    }
  }

  Future<void> forget() async {
    setState(() => error = null);
    try {
      await widget.pairedDevices.clear();
      if (mounted) setState(() => rememberedDeviceId = null);
      await widget.services.disconnectDevice();
      if (mounted) setState(() {});
    } catch (next) {
      if (mounted) setState(() => error = next);
    }
  }

  Future<void> _setCapture(bool enabled) async {
    final device = _connectedDevice;
    setState(() => error = null);
    try {
      if (!enabled) {
        await widget.services.deviceAudio.stop();
      } else if (device != null) {
        await widget.services.connectDevice(device.id);
      }
      if (mounted) setState(() {});
    } catch (next) {
      if (mounted) setState(() => error = next);
    }
  }

  String _phaseLabel(DeviceConnectionPhase phase) => switch (phase) {
    DeviceConnectionPhase.unavailable => 'Unavailable',
    DeviceConnectionPhase.disconnected => 'Disconnected',
    DeviceConnectionPhase.scanning => 'Scanning…',
    DeviceConnectionPhase.connecting => 'Connecting…',
    DeviceConnectionPhase.connected => 'Connected',
    DeviceConnectionPhase.disconnecting => 'Disconnecting…',
    DeviceConnectionPhase.failed => 'Connection failed',
  };

  String _codecLabel(DeviceAudioCodec codec) => switch (codec) {
    DeviceAudioCodec.pcm8 => 'PCM 8 kHz',
    DeviceAudioCodec.pcm16 => 'PCM 16 kHz',
    DeviceAudioCodec.opus => 'Opus 16 kHz',
    DeviceAudioCodec.opusFs320 => 'Opus 16 kHz (fs320)',
    DeviceAudioCodec.unknown => 'Unknown',
  };

  @override
  Widget build(BuildContext context) {
    final phase = _phase;
    final device = snapshot?.device;
    final connected = _connectedDevice != null;
    final capturing = widget.services.deviceAudio.active;
    final lastError = error ?? widget.services.deviceAudio.lastError;
    return PageList(
      title: 'Omi',
      subtitle: 'Your pendant, paired to this phone.',
      children: [
        if (widget.previewMode)
          const BaseTile(
            icon: Icons.visibility_outlined,
            title: 'Device controls unavailable in preview',
            detail: 'Bluetooth scanning and connection are disabled.',
            trailing: Icon(Icons.block_rounded),
          )
        else if (!_mobile)
          const BaseTile(
            icon: Icons.phone_iphone_rounded,
            title: 'Mobile relay required',
            detail:
                'Device pairing is intentionally unavailable on this client.',
            trailing: Icon(Icons.info_outline_rounded),
          )
        else ...[
          BaseTile(
            key: const Key('companion_connection_tile'),
            icon: connected
                ? Icons.bluetooth_connected_rounded
                : Icons.bluetooth_rounded,
            title: device?.name ?? 'No device connected',
            detail: [_phaseLabel(phase), ?snapshot?.message].join(' · '),
            trailing: connected
                ? IconButton(
                    key: const Key('companion_disconnect'),
                    tooltip: 'Disconnect',
                    onPressed: disconnect,
                    icon: const Icon(Icons.link_off_rounded),
                  )
                : const SizedBox.shrink(),
          ),
          if (_desktopNoticeDismissed == false)
            BaseTile(
              key: const Key('companion_desktop_notice_tile'),
              icon: Icons.desktop_mac_outlined,
              title: 'Install the Omi desktop app',
              detail: 'Omi learns more about you from your Mac or Windows PC.',
              trailing: IconButton(
                key: const Key('companion_desktop_notice_dismiss'),
                tooltip: 'Dismiss',
                onPressed: () => unawaited(_dismissDesktopNotice()),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          if (connected && device != null) ...[
            BaseTile(
              key: const Key('companion_battery_tile'),
              icon: Icons.battery_std_rounded,
              title: 'Battery',
              detail: device.batteryLevel == null
                  ? 'Unknown'
                  : '${device.batteryLevel}%',
              trailing: const SizedBox.shrink(),
            ),
            BaseTile(
              key: const Key('companion_codec_tile'),
              icon: Icons.graphic_eq_rounded,
              title: 'Audio codec',
              detail: _codecLabel(device.audioCodec),
              trailing: const SizedBox.shrink(),
            ),
            BaseTile(
              key: const Key('companion_firmware_tile'),
              icon: Icons.memory_rounded,
              title: 'Firmware',
              detail: device.firmwareRevision ?? 'Not reported',
              trailing: const SizedBox.shrink(),
            ),
            if (device.signalStrength case final signal?)
              BaseTile(
                icon: Icons.network_check_rounded,
                title: 'Signal',
                detail: '$signal dBm',
                trailing: const SizedBox.shrink(),
              ),
            BaseTile(
              key: const Key('companion_capture_tile'),
              icon: capturing
                  ? Icons.fiber_manual_record_rounded
                  : Icons.pause_circle_outline_rounded,
              iconColor: capturing ? const Color(0xfff2a78f) : null,
              title: 'Capture',
              detail: capturing
                  ? 'Streaming audio to transcription.'
                  : 'Capture is off.',
              trailing: Switch(
                key: const Key('companion_capture_switch'),
                value: capturing,
                onChanged: (value) => unawaited(_setCapture(value)),
              ),
            ),
          ] else ...[
            BaseTile(
              key: const Key('companion_scan_tile'),
              icon: Icons.bluetooth_searching_rounded,
              title: phase == DeviceConnectionPhase.scanning
                  ? 'Scanning nearby…'
                  : 'Find an Omi device',
              detail: 'Bluetooth permission is requested when you scan.',
              trailing: IconButton(
                key: const Key('companion_scan'),
                tooltip: 'Scan',
                onPressed: phase == DeviceConnectionPhase.scanning
                    ? null
                    : scan,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ),
            if (rememberedDeviceId case final remembered?)
              BaseTile(
                key: const Key('companion_remembered_tile'),
                icon: Icons.history_rounded,
                title: 'Remembered device',
                detail: remembered,
                trailing: IconButton(
                  key: const Key('companion_forget'),
                  tooltip: 'Forget',
                  onPressed: forget,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ),
            for (final found in devices)
              BaseTile(
                icon: Icons.watch_outlined,
                title: found.name,
                detail: [
                  if (found.signalStrength case final signal?) '$signal dBm',
                  if (found.batteryLevel case final battery?)
                    '$battery% battery',
                ].join(' · '),
                trailing: IconButton(
                  key: Key('companion_connect_${found.id}'),
                  tooltip: 'Connect',
                  onPressed: phase == DeviceConnectionPhase.connecting
                      ? null
                      : () => connect(found),
                  icon: const Icon(Icons.add_circle_outline_rounded),
                ),
              ),
          ],
          if (lastError != null)
            BaseTile(
              key: const Key('companion_error_tile'),
              icon: Icons.error_outline_rounded,
              iconColor: const Color(0xfff2a78f),
              title: 'Last error',
              detail: '$lastError',
              trailing: const SizedBox.shrink(),
            ),
        ],
      ],
    );
  }
}

class MobileCaptureScreen extends StatelessWidget {
  const MobileCaptureScreen({
    required this.services,
    required this.transcripts,
    super.key,
  });

  final AppServices services;
  final List<TranscriptDelta> transcripts;

  @override
  Widget build(BuildContext context) {
    final capturing = services.deviceAudio.active;
    return PageList(
      title: 'Capture',
      subtitle: capturing
          ? 'Live transcription is running.'
          : 'Connect your Omi to start capturing.',
      children: [
        BaseTile(
          key: const Key('companion_capture_state_tile'),
          icon: capturing
              ? Icons.fiber_manual_record_rounded
              : Icons.pause_circle_outline_rounded,
          iconColor: capturing ? const Color(0xfff2a78f) : null,
          title: capturing ? 'Capturing' : 'Idle',
          detail: capturing
              ? 'Final segments appear below as they arrive.'
              : 'Recent segments from this session stay listed here.',
          trailing: const SizedBox.shrink(),
        ),
        if (transcripts.isEmpty)
          const BaseTile(
            key: Key('companion_transcripts_empty'),
            icon: Icons.notes_rounded,
            title: 'No transcripts yet',
            detail: 'Captured speech from this session will appear here.',
            trailing: SizedBox.shrink(),
          )
        else
          for (final delta in transcripts)
            BaseTile(
              icon: Icons.notes_rounded,
              title: delta.text,
              detail: _timestamp(delta.occurredAtMs),
              trailing: const SizedBox.shrink(),
            ),
      ],
    );
  }

  String _timestamp(int occurredAtMs) {
    final time = DateTime.fromMillisecondsSinceEpoch(occurredAtMs).toLocal();
    final hours = time.hour.toString().padLeft(2, '0');
    final minutes = time.minute.toString().padLeft(2, '0');
    return '$hours:$minutes';
  }
}

class MobileSettingsScreen extends StatelessWidget {
  const MobileSettingsScreen({
    required this.services,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final bool previewMode;

  static const _appVersion = String.fromEnvironment(
    'OMI_APP_VERSION',
    defaultValue: 'dev',
  );

  @override
  Widget build(BuildContext context) {
    final auth = services.auth;
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        final snapshot = auth.snapshot;
        final session = snapshot.session;
        final consent = snapshot.processingConsent;
        return PageList(
          title: 'Settings',
          subtitle: 'Account, consent, and transcription route.',
          children: [
            BaseTile(
              key: const Key('companion_account_tile'),
              icon: Icons.person_outline_rounded,
              title: session == null
                  ? 'Signed out'
                  : session.displayName ??
                        session.phoneNumber ??
                        session.email ??
                        'Signed in',
              detail: previewMode
                  ? 'Account access is disabled in the interface preview.'
                  : session == null
                  ? services.configurationMessage
                  : 'Signed in.',
              trailing: session == null || previewMode
                  ? const SizedBox.shrink()
                  : IconButton(
                      key: const Key('companion_sign_out'),
                      tooltip: 'Sign out',
                      onPressed: () => unawaited(auth.signOut()),
                      icon: const Icon(Icons.logout_rounded),
                    ),
            ),
            BaseTile(
              key: const Key('companion_consent_tile'),
              icon: Icons.privacy_tip_outlined,
              title: 'Processing consent',
              detail: consent == null
                  ? 'Not granted. Audio never leaves this phone without it.'
                  : 'Granted ${consent.acceptedAt.toLocal().toIso8601String().split('T').first} '
                        '(policy v${consent.policyVersion}).',
              trailing: consent == null || previewMode
                  ? const SizedBox.shrink()
                  : IconButton(
                      key: const Key('companion_revoke_consent'),
                      tooltip: 'Revoke',
                      onPressed: () =>
                          unawaited(auth.revokeProcessingConsent()),
                      icon: const Icon(Icons.block_rounded),
                    ),
            ),
            _RouteTile(services: services),
            const BaseTile(
              key: Key('companion_version_tile'),
              icon: Icons.info_outline_rounded,
              title: 'App version',
              detail: _appVersion,
              trailing: SizedBox.shrink(),
            ),
          ],
        );
      },
    );
  }
}

class _RouteTile extends StatefulWidget {
  const _RouteTile({required this.services});

  final AppServices services;

  @override
  State<_RouteTile> createState() => _RouteTileState();
}

class _RouteTileState extends State<_RouteTile> {
  late Future<ProviderCredential?> credential = _read();

  Future<ProviderCredential?> _read() async {
    try {
      return await widget.services.providerCredential;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ProviderCredential?>(
    future: credential,
    builder: (context, snapshot) {
      final byok = snapshot.data;
      return BaseTile(
        key: const Key('companion_route_tile'),
        icon: Icons.route_rounded,
        title: 'Transcription route',
        detail: byok == null
            ? 'Managed Omi transcription.'
            : 'Bring your own key · ${byok.model}',
        trailing: const SizedBox.shrink(),
      );
    },
  );
}
