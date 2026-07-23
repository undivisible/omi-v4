import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_services.dart';
import '../currents/currents.dart';
import '../device/device.dart';
import '../features/setup_account_screens.dart' show EventKitProactiveSyncTile;
import '../native/native_hub.dart';
import '../providers/providers.dart';

const _paper = Color(0xfff7f6f1);
const _surface = Color(0xfffffefa);
const _cream = Color(0xfffffcec);
const _ink = Color(0xff171716);
const _inkSoft = Color(0xff706e68);
const _hairline = Color(0x14171716);
const _teal = Color(0xff2f9d8a);
const _coral = Color(0xffd97757);
const _inkSheet = Color(0xff1c1c1a);

// Mirrors the pendant firmware LED semantics (set_led_state in the upstream
// firmware): solid blue while connected, red while disconnected. The charging
// LED states (solid or blinking green) cannot be mirrored because charging
// state is not surfaced over BLE by the relay today.
const _stateBlue = Color(0xff4a8fdd);
const _stateRed = Color(0xffd9564a);

bool _darkMode(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _pageInk(BuildContext context) => _darkMode(context) ? _cream : _ink;

Color _pageInkSoft(BuildContext context) =>
    _darkMode(context) ? const Color(0xffa6a49c) : _inkSoft;

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

  @override
  void initState() {
    super.initState();
    _nativeEventSubscription = widget.services.nativeEvents.listen((event) {
      if (event case NativeEventTranscriptDelta(
        :final value,
      ) when value.finalSegment) {
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
    final dark = _darkMode(context);
    return Theme(
      data: Theme.of(context).copyWith(
        brightness: dark ? Brightness.dark : Brightness.light,
        colorScheme: const ColorScheme.light(
          primary: _ink,
          surface: _surface,
          onSurface: _ink,
          onSurfaceVariant: _inkSoft,
          secondary: _teal,
        ).copyWith(brightness: dark ? Brightness.dark : Brightness.light),
        textTheme: Theme.of(
          context,
        ).textTheme.apply(bodyColor: _ink, displayColor: _ink),
        iconTheme: const IconThemeData(color: _inkSoft),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? _cream : _surface,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? _teal
                : const Color(0x22171716),
          ),
        ),
        dividerColor: _hairline,
      ),
      child: Scaffold(
        key: const Key('companion_home'),
        backgroundColor: dark ? _ink : _paper,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Opacity(opacity: dark ? .38 : 1, child: const _WarmGlows()),
            MobilePendantPage(
              services: widget.services,
              pairedDevices: _pairedDevices,
              transcripts: _transcripts,
              previewMode: widget.previewMode,
            ),
          ],
        ),
      ),
    );
  }
}

class _WarmGlows extends StatelessWidget {
  const _WarmGlows();

  @override
  Widget build(BuildContext context) => const IgnorePointer(
    child: Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-1.1, -.9),
              radius: 1.1,
              colors: [Color(0x2e73d5c4), Color(0x00f7f6f1)],
              stops: [0, .72],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(1.2, -.6),
              radius: 1.05,
              colors: [Color(0x2496c4ff), Color(0x00f7f6f1)],
              stops: [0, .7],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(.7, 1.25),
              radius: 1.15,
              colors: [Color(0x26f2a78f), Color(0x00f7f6f1)],
              stops: [0, .74],
            ),
          ),
        ),
      ],
    ),
  );
}

class MobilePendantPage extends StatefulWidget {
  const MobilePendantPage({
    required this.services,
    required this.pairedDevices,
    required this.transcripts,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final PairedDeviceStore pairedDevices;
  final List<TranscriptDelta> transcripts;
  final bool previewMode;

  @override
  State<MobilePendantPage> createState() => MobilePendantPageState();
}

class MobilePendantPageState extends State<MobilePendantPage> {
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
    if (!widget.previewMode && widget.services.productionReady) {
      final currents = widget.services.currents;
      if (currents != null) unawaited(currents.load());
    }
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

  Future<void> reconnect() async {
    final remembered = rememberedDeviceId;
    if (remembered == null) {
      await scan();
      return;
    }
    setState(() => error = null);
    try {
      await widget.services.connectDevice(remembered);
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

  List<Widget> _deviceTiles(
    DeviceConnectionPhase phase,
    RelayDevice? device,
    bool connected,
    bool capturing,
    Object? lastError,
  ) => [
    if (widget.previewMode)
      const _PaperTile(
        icon: Icons.visibility_outlined,
        title: 'Device controls unavailable in preview',
        detail: 'Bluetooth scanning and connection are disabled.',
      )
    else if (!_mobile)
      const _PaperTile(
        icon: Icons.phone_iphone_rounded,
        title: 'Mobile relay required',
        detail: 'Device pairing is intentionally unavailable on this client.',
      )
    else ...[
      if (connected)
        _PaperTile(
          key: const Key('companion_connection_tile'),
          icon: Icons.bluetooth_connected_rounded,
          iconColor: _stateBlue,
          title: device?.name ?? 'No device connected',
          detail: [_phaseLabel(phase), ?snapshot?.message].join(' · '),
          trailing: IconButton(
            key: const Key('companion_disconnect'),
            tooltip: 'Disconnect',
            onPressed: disconnect,
            icon: const Icon(Icons.link_off_rounded),
          ),
        ),
      if (connected && device != null) ...[
        _PaperTile(
          key: const Key('companion_codec_tile'),
          icon: Icons.graphic_eq_rounded,
          title: 'Audio codec',
          detail: _codecLabel(device.audioCodec),
        ),
        _PaperTile(
          key: const Key('companion_firmware_tile'),
          icon: Icons.memory_rounded,
          title: 'Firmware',
          detail: device.firmwareRevision ?? 'Not reported',
        ),
        if (device.signalStrength case final signal?)
          _PaperTile(
            icon: Icons.network_check_rounded,
            title: 'Signal',
            detail: '$signal dBm',
          ),
        _PaperTile(
          key: const Key('companion_capture_tile'),
          icon: capturing
              ? Icons.fiber_manual_record_rounded
              : Icons.pause_circle_outline_rounded,
          iconColor: capturing ? _coral : null,
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
        for (final found in devices)
          _PaperTile(
            icon: Icons.watch_outlined,
            title: found.name,
            detail: [
              if (found.signalStrength case final signal?) '$signal dBm',
              if (found.batteryLevel case final battery?) '$battery% battery',
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
        _PaperTile(
          key: const Key('companion_error_tile'),
          icon: Icons.error_outline_rounded,
          iconColor: _coral,
          title: 'Last error',
          detail: '$lastError',
        ),
    ],
  ];

  List<Widget> _transcriptTiles() => [
    if (widget.transcripts.isEmpty)
      const _PaperTile(
        key: Key('companion_transcripts_empty'),
        icon: Icons.notes_rounded,
        title: 'No transcripts yet',
        detail: 'Captured speech from this session will appear here.',
      )
    else
      for (final delta in widget.transcripts)
        _PaperTile(
          icon: Icons.notes_rounded,
          title: delta.text,
          detail: _timestamp(delta.occurredAtMs),
        ),
  ];

  String _timestamp(int occurredAtMs) {
    final time = DateTime.fromMillisecondsSinceEpoch(occurredAtMs).toLocal();
    final hours = time.hour.toString().padLeft(2, '0');
    final minutes = time.minute.toString().padLeft(2, '0');
    return '$hours:$minutes';
  }

  @override
  Widget build(BuildContext context) {
    final phase = _phase;
    final device = snapshot?.device;
    final connected = _connectedDevice != null;
    final capturing = widget.services.deviceAudio.active;
    final lastError = error ?? widget.services.deviceAudio.lastError;
    final capturedSegments = widget.transcripts.length;
    final capturedMs = widget.transcripts.fold<int>(
      0,
      (sum, delta) => sum + math.max(0, delta.endMs - delta.startMs),
    );
    final busy =
        phase == DeviceConnectionPhase.scanning ||
        phase == DeviceConnectionPhase.connecting ||
        phase == DeviceConnectionPhase.disconnecting;
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final pendantWidth = math.min(constraints.maxWidth * .82, 420.0);
        final heroHeight = math.min(
          constraints.maxHeight * .5,
          pendantWidth * .78 + 222,
        );
        // Push the hero (pendant image, title, status, battery) down from
        // the very top edge: respect the safe-area inset and add extra
        // breathing room so the cord isn't flush against the top.
        final topInset = MediaQuery.paddingOf(context).top;
        return Column(
          key: const Key('companion_pendant_column'),
          children: [
            SizedBox(height: topInset + 52),
            SizedBox(
              height: heroHeight,
              child: OverflowBox(
                maxHeight: double.infinity,
                alignment: Alignment.bottomCenter,
                child: _PendantHero(
                  deviceName: device?.name,
                  phaseLabel: _phaseLabel(phase),
                  connected: connected,
                  batteryLevel: connected ? device?.batteryLevel : null,
                  busy: busy,
                  onReconnect: () => unawaited(reconnect()),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                key: const Key('companion_page_sections'),
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
                children: [
                  _StatsRow(
                    capturedSegments: capturedSegments,
                    capturedMinutes: (capturedMs / 60000).ceil(),
                    capturing: capturing,
                  ),
                  if (!widget.previewMode &&
                      widget.services.productionReady &&
                      widget.services.currents != null)
                    _MobileTasksSection(currents: widget.services.currents!),
                  const SizedBox(height: 22),
                  const _SectionLabel('DEVICE'),
                  ..._withGaps(
                    _deviceTiles(
                      phase,
                      device,
                      connected,
                      capturing,
                      lastError,
                    ),
                  ),
                  if (_desktopNoticeDismissed == false) ...[
                    const SizedBox(height: 22),
                    _DesktopCta(
                      onDismiss: () => unawaited(_dismissDesktopNotice()),
                    ),
                  ],
                  const SizedBox(height: 22),
                  const _SectionLabel('THIS SESSION'),
                  SizedBox(
                    height: 232,
                    child: ListView(
                      key: const Key('companion_session_list'),
                      padding: EdgeInsets.zero,
                      children: [..._withGaps(_transcriptTiles())],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        );
      },
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        body,
        Positioned(
          top: 0,
          right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: 8, right: 14),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _surface,
                  border: Border.all(color: _hairline),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  key: const Key('companion_settings_button'),
                  tooltip: 'Settings',
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_outlined, size: 20),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openSettings() {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: _darkMode(context) ? _inkSheet : _paper,
        isScrollControlled: true,
        useSafeArea: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (sheetContext) => _SettingsSheet(
          services: widget.services,
          previewMode: widget.previewMode,
          rememberedDeviceId: () => rememberedDeviceId,
          onForget: forget,
        ),
      ),
    );
  }
}

class _MobileTasksSection extends StatelessWidget {
  const _MobileTasksSection({required this.currents});

  final CurrentsController currents;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: currents,
    builder: (context, _) {
      if (currents.error != null || currents.items.isEmpty) {
        return const SizedBox.shrink();
      }
      final tasks = currents.items.take(2).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 22),
          const _SectionLabel('TASKS'),
          ..._withGaps([
            for (final task in tasks)
              _PaperTile(
                key: ValueKey('companion_task_${task.item.id}'),
                icon: Icons.radio_button_unchecked_rounded,
                title: task.title,
                detail: task.sourceKind == null
                    ? task.summary
                    : '${task.summary} · ${task.sourceKind!.toUpperCase()}',
                trailing: IconButton(
                  key: ValueKey('companion_task_complete_${task.item.id}'),
                  tooltip: 'Complete',
                  onPressed: () => unawaited(currents.dismiss(task.item.id)),
                  icon: const Icon(Icons.check_circle_outline_rounded),
                ),
              ),
          ]),
        ],
      );
    },
  );
}

List<Widget> _withGaps(List<Widget> tiles) => [
  for (final tile in tiles) ...[const SizedBox(height: 10), tile],
];

class _PendantHero extends StatefulWidget {
  const _PendantHero({
    required this.deviceName,
    required this.phaseLabel,
    required this.connected,
    required this.batteryLevel,
    required this.busy,
    required this.onReconnect,
  });

  final String? deviceName;
  final String phaseLabel;
  final bool connected;
  final int? batteryLevel;
  final bool busy;
  final VoidCallback onReconnect;

  @override
  State<_PendantHero> createState() => _PendantHeroState();
}

class _PendantHeroState extends State<_PendantHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sway = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  bool _animationsDisabled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animationsDisabled = MediaQuery.disableAnimationsOf(context);
    if (_animationsDisabled) {
      _sway.stop();
    } else if (!_sway.isAnimating) {
      _sway.repeat();
    }
  }

  @override
  void dispose() {
    _sway.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animationsDisabled = _animationsDisabled;
    final width = MediaQuery.sizeOf(context).width;
    final pendantWidth = math.min(width * .82, 420.0);
    final connected = widget.connected;
    Widget pendant = Image.asset(
      'assets/images/omi_pendant.png',
      key: const Key('companion_pendant_image'),
      width: pendantWidth,
      fit: BoxFit.fitWidth,
      excludeFromSemantics: true,
    );
    if (!connected) {
      pendant = Opacity(
        key: const Key('companion_pendant_faded'),
        opacity: .35,
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            .2126, .7152, .0722, 0, 0, //
            .2126, .7152, .0722, 0, 0, //
            .2126, .7152, .0722, 0, 0, //
            0, 0, 0, 1, 0,
          ]),
          child: pendant,
        ),
      );
    }
    final glowSize = pendantWidth * 1.3;
    final stateColor = connected
        ? _stateBlue
        : (widget.busy ? null : _stateRed);
    Color glow(Color warm, double blend) =>
        stateColor == null ? warm : Color.lerp(warm, stateColor, blend)!;
    return Column(
      children: [
        Align(
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: pendantWidth * .55 - glowSize / 2,
                child: IgnorePointer(
                  child: Container(
                    key: const Key('companion_pendant_glow'),
                    width: glowSize,
                    height: glowSize,
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        colors: [
                          glow(
                            const Color(0xfff2a78f),
                            .3,
                          ).withValues(alpha: connected ? .32 : .14),
                          glow(
                            const Color(0xfff6c9a0),
                            .22,
                          ).withValues(alpha: connected ? .16 : .07),
                          const Color(0x00f2a78f),
                        ],
                        stops: const [0, .45, 1],
                      ),
                    ),
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: _sway,
                child: pendant,
                builder: (context, child) {
                  final t = _sway.value * 2 * math.pi;
                  final angle = animationsDisabled ? 0.0 : math.sin(t) * .012;
                  return Transform.rotate(
                    angle: angle,
                    alignment: Alignment.topCenter,
                    child: child,
                  );
                },
              ),
            ],
          ),
        ),
        Transform.translate(
          offset: Offset(0, -pendantWidth * .22),
          child: Column(
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Omi',
                  style: TextStyle(
                    fontSize: 46,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                    color: _pageInk(context),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              if (!connected) ...[
                Semantics(
                  label: 'Device status: ${widget.phaseLabel}',
                  excludeSemantics: true,
                  child: Text(
                    widget.busy ? widget.phaseLabel : 'Omi disconnected',
                    key: const Key('companion_disconnected_label'),
                    style: TextStyle(
                      fontSize: 15,
                      color: widget.busy
                          ? _pageInkSoft(context)
                          : Color.lerp(_pageInkSoft(context), _stateRed, .6),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                OutlinedButton(
                  key: const Key('companion_reconnect'),
                  onPressed: widget.busy ? null : widget.onReconnect,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _ink,
                    side: const BorderSide(color: _hairline),
                    backgroundColor: _surface,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 26,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('Reconnect'),
                ),
              ] else
                Semantics(
                  label: widget.deviceName == null
                      ? 'Device status: ${widget.phaseLabel}'
                      : '${widget.deviceName}: ${widget.phaseLabel}',
                  excludeSemantics: true,
                  child: Text(
                    widget.deviceName == null
                        ? widget.phaseLabel
                        : '${widget.deviceName} · ${widget.phaseLabel}',
                    style: TextStyle(
                      fontSize: 15,
                      color: Color.lerp(_pageInkSoft(context), _stateBlue, .55),
                    ),
                  ),
                ),
              if (widget.batteryLevel case final battery?) ...[
                const SizedBox(height: 10),
                Semantics(
                  label: 'Battery $battery percent',
                  excludeSemantics: true,
                  child: DecoratedBox(
                    key: const Key('companion_battery_tile'),
                    decoration: BoxDecoration(
                      color: _surface,
                      border: Border.all(color: _hairline),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            battery > 20
                                ? Icons.battery_std_rounded
                                : Icons.battery_alert_rounded,
                            size: 18,
                            color: battery > 20 ? _teal : _coral,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '$battery%',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.capturedSegments,
    required this.capturedMinutes,
    required this.capturing,
  });

  final int capturedSegments;
  final int capturedMinutes;
  final bool capturing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _StatCard(
          key: const Key('companion_stat_segments'),
          value: '$capturedSegments',
          label: 'segments captured',
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: _StatCard(
          key: const Key('companion_stat_minutes'),
          value: '$capturedMinutes',
          label: 'minutes transcribed',
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: _StatCard(
          key: const Key('companion_stat_capture'),
          value: capturing ? 'Live' : 'Idle',
          label: 'capture state',
          accent: capturing ? _coral : null,
        ),
      ),
    ],
  );
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.value,
    required this.label,
    this.accent,
    super.key,
  });

  final String value;
  final String label;
  final Color? accent;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$value $label',
    excludeSemantics: true,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _hairline),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0d171716),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: accent ?? _ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: _inkSoft),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.43,
        color: _pageInkSoft(context),
      ),
    ),
  );
}

class _PaperTile extends StatelessWidget {
  const _PaperTile({
    required this.icon,
    required this.title,
    required this.detail,
    this.trailing,
    this.iconColor,
    super.key,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _hairline),
      borderRadius: BorderRadius.circular(18),
    ),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, color: iconColor ?? _inkSoft),
      title: Text(
        title,
        style: const TextStyle(
          color: _ink,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          detail,
          style: const TextStyle(color: _inkSoft, fontSize: 13, height: 1.4),
        ),
      ),
      trailing: trailing,
    ),
  );
}

class _DesktopCta extends StatelessWidget {
  const _DesktopCta({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const Key('companion_desktop_notice_tile'),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xffeef7f0), Color(0xfffdf3ea)],
      ),
      border: Border.all(color: _hairline),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.desktop_mac_outlined, color: _teal),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Install the Omi desktop app',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'Omi learns more about you from your Mac or Windows PC.',
                  style: TextStyle(color: _inkSoft, fontSize: 13, height: 1.4),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('companion_desktop_notice_dismiss'),
            tooltip: 'Dismiss',
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    ),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.services,
    required this.previewMode,
    required this.rememberedDeviceId,
    required this.onForget,
  });

  final AppServices services;
  final bool previewMode;
  final String? Function() rememberedDeviceId;
  final Future<void> Function() onForget;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  bool _deleting = false;

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
    required Key confirmKey,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: confirmKey,
            style: TextButton.styleFrom(foregroundColor: _coral),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _resetPendant() async {
    final confirmed = await _confirm(
      title: 'Reset pendant?',
      message:
          'This disconnects your pendant and forgets it on this phone. '
          'You can pair it again any time.',
      action: 'Reset',
      confirmKey: const Key('companion_reset_pendant_confirm'),
    );
    if (!confirmed) return;
    await widget.onForget();
    if (mounted) setState(() {});
  }

  Future<void> _deleteAccount() async {
    final confirmed = await _confirm(
      title: 'Delete account?',
      message:
          'This permanently deletes your account and everything Omi has '
          'learned. This cannot be undone.',
      action: 'Delete',
      confirmKey: const Key('companion_delete_account_confirm'),
    );
    if (!confirmed || _deleting) return;
    setState(() => _deleting = true);
    try {
      await widget.services.deleteAccount();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _deleting = false);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Could not delete account: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final remembered = widget.rememberedDeviceId();
    return SafeArea(
      top: false,
      child: ListView(
        key: const Key('companion_settings_sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
        children: [
          const _SectionLabel('SETTINGS'),
          ..._withGaps(
            _MobileSettingsSection.tiles(
              context,
              services: widget.services,
              previewMode: widget.previewMode,
            ),
          ),
          if (remembered != null) ...[
            const SizedBox(height: 22),
            const _SectionLabel('DEVICE'),
            ..._withGaps([
              _PaperTile(
                key: const Key('companion_remembered_tile'),
                icon: Icons.history_rounded,
                title: 'Remembered device',
                detail: remembered,
                trailing: IconButton(
                  key: const Key('companion_forget'),
                  tooltip: 'Forget',
                  onPressed: () => unawaited(
                    widget.onForget().then((_) {
                      if (mounted) setState(() {});
                    }),
                  ),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ),
              _PaperTile(
                key: const Key('companion_reset_pendant'),
                icon: Icons.restart_alt_rounded,
                iconColor: _coral,
                title: 'Reset pendant',
                detail: 'Disconnect and forget this pendant.',
                trailing: IconButton(
                  key: const Key('companion_reset_pendant_button'),
                  tooltip: 'Reset pendant',
                  onPressed: () => unawaited(_resetPendant()),
                  icon: const Icon(Icons.restart_alt_rounded, color: _coral),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 22),
          const _SectionLabel('CALENDAR & REMINDERS'),
          EventKitProactiveSyncTile(
            key: const Key('companion_eventkit_proactive_sync'),
            previewMode: widget.previewMode,
          ),
          if (!widget.previewMode) ...[
            const SizedBox(height: 22),
            const _SectionLabel('DANGER ZONE'),
            ..._withGaps([
              _PaperTile(
                key: const Key('companion_delete_account'),
                icon: Icons.delete_forever_rounded,
                iconColor: _coral,
                title: 'Delete account',
                detail: 'Permanently delete your account and data.',
                trailing: IconButton(
                  key: const Key('companion_delete_account_button'),
                  tooltip: 'Delete account',
                  onPressed: _deleting
                      ? null
                      : () => unawaited(_deleteAccount()),
                  icon: const Icon(Icons.delete_forever_rounded, color: _coral),
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}

class _MobileSettingsSection {
  static const _appVersion = String.fromEnvironment(
    'OMI_APP_VERSION',
    defaultValue: 'dev',
  );

  static List<Widget> tiles(
    BuildContext context, {
    required AppServices services,
    required bool previewMode,
  }) => [
    _AccountTiles(services: services, previewMode: previewMode),
    _RouteTile(services: services),
    const _PaperTile(
      key: Key('companion_version_tile'),
      icon: Icons.info_outline_rounded,
      title: 'App version',
      detail: _appVersion,
    ),
  ];
}

class _AccountTiles extends StatelessWidget {
  const _AccountTiles({required this.services, required this.previewMode});

  final AppServices services;
  final bool previewMode;

  @override
  Widget build(BuildContext context) {
    final auth = services.auth;
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        final snapshot = auth.snapshot;
        final session = snapshot.session;
        final consent = snapshot.processingConsent;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PaperTile(
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
                  ? null
                  : IconButton(
                      key: const Key('companion_sign_out'),
                      tooltip: 'Sign out',
                      onPressed: () => unawaited(auth.signOut()),
                      icon: const Icon(Icons.logout_rounded),
                    ),
            ),
            const SizedBox(height: 10),
            _PaperTile(
              key: const Key('companion_consent_tile'),
              icon: Icons.privacy_tip_outlined,
              title: 'Processing consent',
              detail: consent == null
                  ? 'Not granted. Audio never leaves this phone without it.'
                  : 'Granted ${consent.acceptedAt.toLocal().toIso8601String().split('T').first} '
                        '(policy v${consent.policyVersion}).',
              trailing: consent == null || previewMode
                  ? null
                  : IconButton(
                      key: const Key('companion_revoke_consent'),
                      tooltip: 'Revoke',
                      onPressed: () =>
                          unawaited(auth.revokeProcessingConsent()),
                      icon: const Icon(Icons.block_rounded),
                    ),
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
      return _PaperTile(
        key: const Key('companion_route_tile'),
        icon: Icons.route_rounded,
        title: 'Transcription route',
        detail: byok == null
            ? 'Managed Omi transcription.'
            : 'Bring your own key · ${byok.model}',
      );
    },
  );
}
