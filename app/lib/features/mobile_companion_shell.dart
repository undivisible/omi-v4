import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import '../app_services.dart';
import '../auth/auth.dart';
import '../currents/currents.dart';
import '../device/device.dart';
import '../features/setup_account_screens.dart' show EventKitProactiveSyncTile;
import '../native/native_hub.dart';
import 'capture_notifier.dart';
import 'mobile_update_check.dart';
import 'transcript_log_store.dart';

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

// Vertical rhythm for the mobile home. Kept deliberately tight: the phone
// screen only has room for the hero plus two short sections before the fold.
const _sectionGap = 14.0;
const _tileGap = 8.0;

/// Where the "Install the Omi desktop app" row sends people. Overridable at
/// build time so a fork can point at its own download page.
const desktopDownloadUrl = String.fromEnvironment(
  'OMI_DESKTOP_DOWNLOAD_URL',
  defaultValue: 'https://github.com/undivisible/omi-v4/releases',
);

/// Opens an external link. Injected so widget tests can observe taps without
/// reaching for the platform channel behind `url_launcher`.
typedef LinkOpener = Future<void> Function(Uri uri);

Future<void> _openExternalLink(Uri uri) async {
  try {
    await url_launcher.launchUrl(
      uri,
      mode: url_launcher.LaunchMode.externalApplication,
    );
  } catch (_) {}
}

bool _darkMode(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _pageInk(BuildContext context) => _darkMode(context) ? _cream : _ink;

Color _pageInkSoft(BuildContext context) =>
    _darkMode(context) ? const Color(0xffa6a49c) : _inkSoft;

class MobileCompanionShell extends StatefulWidget {
  const MobileCompanionShell({
    required this.services,
    this.pairedDevices,
    this.transcriptLog,
    this.captureNotifier,
    this.captureEnabledStore,
    this.updateChecker,
    this.openLink,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final PairedDeviceStore? pairedDevices;
  final TranscriptLogStore? transcriptLog;
  final CaptureNotifier? captureNotifier;
  final CaptureEnabledStore? captureEnabledStore;
  final MobileUpdateChecker? updateChecker;
  final LinkOpener? openLink;
  final bool previewMode;

  @override
  State<MobileCompanionShell> createState() => _MobileCompanionShellState();
}

class _MobileCompanionShellState extends State<MobileCompanionShell> {
  static const _maxTranscripts = 100;

  late final PairedDeviceStore _pairedDevices =
      widget.pairedDevices ?? PreferencesPairedDeviceStore();
  late final TranscriptLogStore _transcriptLog =
      widget.transcriptLog ?? PreferencesTranscriptLogStore();
  late final CaptureNotifier _captureNotifier =
      widget.captureNotifier ??
      (widget.previewMode
          ? const NoopCaptureNotifier()
          : LocalCaptureNotifier());
  final List<TranscriptDelta> _transcripts = [];
  // The most recent interim (non-final) transcript text, rendered live under
  // the hero while the user is speaking. Cleared once the segment finalizes.
  String _interimText = '';
  StreamSubscription<NativeEvent>? _nativeEventSubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreTranscripts());
    _nativeEventSubscription = widget.services.nativeEvents.listen((event) {
      if (event case NativeEventTranscriptDelta(:final value)) {
        if (!mounted) return;
        if (!value.finalSegment) {
          setState(() => _interimText = value.text);
          return;
        }
        setState(() {
          _interimText = '';
          _transcripts.insert(0, value);
          if (_transcripts.length > _maxTranscripts) {
            _transcripts.removeRange(_maxTranscripts, _transcripts.length);
          }
        });
        unawaited(
          _transcriptLog.save(List.of(_transcripts)).catchError((Object _) {}),
        );
      }
    }, onError: (Object error, StackTrace stackTrace) {});
  }

  Future<void> _restoreTranscripts() async {
    List<TranscriptDelta> restored;
    try {
      restored = await _transcriptLog.read();
    } catch (_) {
      restored = const [];
    }
    if (!mounted || restored.isEmpty) return;
    setState(() {
      final known = _transcripts.map((delta) => delta.segmentId).toSet();
      _transcripts.addAll(
        restored.where((delta) => !known.contains(delta.segmentId)),
      );
      if (_transcripts.length > _maxTranscripts) {
        _transcripts.removeRange(_maxTranscripts, _transcripts.length);
      }
    });
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
              interimText: _interimText,
              captureNotifier: _captureNotifier,
              captureEnabledStore: widget.captureEnabledStore,
              updateChecker: widget.updateChecker,
              openLink: widget.openLink,
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
    required this.captureNotifier,
    this.captureEnabledStore,
    this.updateChecker,
    this.openLink,
    this.interimText = '',
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final PairedDeviceStore pairedDevices;
  final List<TranscriptDelta> transcripts;
  final CaptureNotifier captureNotifier;
  final CaptureEnabledStore? captureEnabledStore;
  final MobileUpdateChecker? updateChecker;
  final LinkOpener? openLink;
  final String interimText;
  final bool previewMode;

  @override
  State<MobilePendantPage> createState() => MobilePendantPageState();
}

class MobilePendantPageState extends State<MobilePendantPage> {
  static const desktopNoticeKey = 'desktop_install_notice_dismissed_v1';

  late final DeviceRelayService relay = widget.services.deviceRelay;
  late final CaptureEnabledStore _captureEnabledStore =
      widget.captureEnabledStore ?? PreferencesCaptureEnabledStore();
  List<RelayDevice> devices = const [];
  DeviceRelaySnapshot? snapshot;
  Object? error;
  String? rememberedDeviceId;
  bool _reconnectAttempted = false;
  bool? _desktopNoticeDismissed;
  // Capture is always on by default: connecting the pendant starts streaming
  // and only this switch (rendered under the minutes chip) turns it off.
  bool _captureEnabled = true;
  bool _syncingCapture = false;
  // A connect this page started already brings capture up on its own, so the
  // snapshot that lands mid-connect must not race it with a second attempt.
  bool _connectInFlight = false;
  MobileRelease? _update;
  StreamSubscription<DeviceRelaySnapshot>? _snapshotSubscription;
  final ScrollController _scrollController = ScrollController();
  // Drives the hero blur/fade. Only the hero reads this; the rest of the page
  // scrolls normally, so the value lives outside setState to avoid rebuilding
  // the whole list on every scroll frame.
  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0);

  bool get _mobile => relay.role == DeviceRelayRole.mobileOwner;

  DeviceConnectionPhase get _phase =>
      snapshot?.phase ?? DeviceConnectionPhase.disconnected;

  RelayDevice? get _connectedDevice =>
      _phase == DeviceConnectionPhase.connected ? snapshot?.device : null;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(
      () => _scrollOffset.value = _scrollController.hasClients
          ? _scrollController.offset
          : 0,
    );
    snapshot = relay.lastSnapshot;
    _snapshotSubscription = relay.snapshots.listen((next) {
      if (mounted) setState(() => snapshot = next);
      _syncCaptureWithConnection();
    });
    unawaited(_restoreCaptureEnabled());
    if (!widget.previewMode) unawaited(_ensureProcessingConsent());
    if (!widget.previewMode && _mobile) unawaited(_restorePairing());
    unawaited(_loadDesktopNotice());
    if (!widget.previewMode) unawaited(_checkForUpdate());
    if (!widget.previewMode && widget.services.productionReady) {
      final currents = widget.services.currents;
      if (currents != null) unawaited(currents.load());
    }
  }

  // Processing consent is collected once, explicitly, during onboarding, and
  // capture is gated on the receipt (AppServices.productionReady). The mobile
  // settings sheet no longer surfaces a consent tile, so a receipt that went
  // missing — reinstall, cleared preferences, a persistence failure — would
  // otherwise leave capture permanently blocked with no way back. Re-record
  // the receipt for the signed-in account instead of failing silently.
  Future<void> _ensureProcessingConsent() async {
    final auth = widget.services.auth;
    final snapshot = auth.snapshot;
    if (snapshot.phase != AuthPhase.signedIn ||
        snapshot.hasProcessingAuthority) {
      return;
    }
    await auth.grantProcessingConsent();
  }

  Future<void> _checkForUpdate() async {
    final checker = widget.updateChecker ?? MobileUpdateChecker();
    final release = await checker.check();
    if (!mounted || release == null) return;
    setState(() => _update = release);
  }

  Future<void> _restoreCaptureEnabled() async {
    bool enabled;
    try {
      enabled = await _captureEnabledStore.read();
    } catch (_) {
      enabled = true;
    }
    if (!mounted) return;
    setState(() => _captureEnabled = enabled);
    _syncCaptureWithConnection();
  }

  // Keeps the audio stream matched to the switch: connecting (or reconnecting)
  // a pendant resumes capture on its own, and flipping the switch off stops it
  // even when the connection comes back later.
  void _syncCaptureWithConnection() {
    if (_syncingCapture || _connectInFlight || widget.previewMode) return;
    if (_connectedDevice == null) return;
    final active = widget.services.deviceAudio.active;
    if (active == _captureEnabled) return;
    _syncingCapture = true;
    unawaited(
      _setCapture(_captureEnabled).whenComplete(() => _syncingCapture = false),
    );
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

  Future<void> _dismissUpdate(MobileRelease release) async {
    setState(() => _update = null);
    await (widget.updateChecker ?? MobileUpdateChecker()).dismiss(release);
  }

  void _open(Uri uri) => unawaited((widget.openLink ?? _openExternalLink)(uri));

  Future<void> _restorePairing() async {
    String? remembered;
    try {
      remembered = await widget.pairedDevices.read();
    } catch (_) {
      remembered = null;
    }
    if (!mounted || remembered == null) return;
    setState(() => rememberedDeviceId = remembered);
    if (_reconnectAttempted || _phase != DeviceConnectionPhase.disconnected) {
      return;
    }
    _reconnectAttempted = true;
    _connectInFlight = true;
    try {
      await widget.services.connectDevice(remembered);
      unawaited(relay.sendHaptic(2));
    } catch (next) {
      if (mounted) setState(() => error = next);
    } finally {
      _connectInFlight = false;
      _syncCaptureWithConnection();
    }
  }

  @override
  void dispose() {
    unawaited(_snapshotSubscription?.cancel());
    _scrollController.dispose();
    _scrollOffset.dispose();
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
    setState(() => error = null);
    _connectInFlight = true;
    try {
      var remembered = rememberedDeviceId;
      if (remembered == null) {
        final found = await relay.scan();
        if (!mounted) return;
        setState(() => devices = found);
        if (found.isEmpty) return;
        remembered = found.first.id;
      }
      await widget.services.connectDevice(remembered);
      await widget.pairedDevices.save(remembered);
      if (mounted) setState(() => rememberedDeviceId = remembered);
      unawaited(relay.sendHaptic(2));
    } catch (next) {
      if (mounted) setState(() => error = next);
    } finally {
      _connectInFlight = false;
      _syncCaptureWithConnection();
    }
  }

  Future<void> connect(RelayDevice device) async {
    setState(() => error = null);
    _connectInFlight = true;
    try {
      await widget.services.connectDevice(device.id);
      await widget.pairedDevices.save(device.id);
      if (mounted) setState(() => rememberedDeviceId = device.id);
      unawaited(relay.sendHaptic(2));
    } catch (next) {
      if (mounted) setState(() => error = next);
    } finally {
      _connectInFlight = false;
      _syncCaptureWithConnection();
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
        // Reflect the idle state on the pendant LED (red) via the firmware
        // capture-state characteristic; a no-op on firmware without it.
        unawaited(relay.writeCaptureLed(false));
        unawaited(widget.captureNotifier.captureStopped());
      } else if (device != null) {
        await widget.services.connectDevice(device.id);
        unawaited(relay.writeCaptureLed(true));
        // Post an ambient local notification and surface the segment in the
        // conversations list (wired via the transcript log) when a capture
        // starts.
        unawaited(
          widget.captureNotifier.captureStarted(deviceName: device.name),
        );
      }
      if (mounted) setState(() {});
    } catch (next) {
      if (mounted) setState(() => error = next);
    }
  }

  // The explicit capture switch under the minutes chip. Capture otherwise
  // runs whenever the pendant is connected, so this is the only control that
  // turns it off — and the choice is remembered across launches.
  void _setCaptureEnabled(bool enabled) {
    if (_captureEnabled == enabled) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _captureEnabled = enabled);
    unawaited(_captureEnabledStore.save(enabled).catchError((Object _) {}));
    if (_connectedDevice == null) return;
    _syncingCapture = true;
    unawaited(_setCapture(enabled).whenComplete(() => _syncingCapture = false));
  }

  // Long-press the pendant image to disconnect, with a haptic + relay confirm
  // so it cannot be triggered by accident.
  Future<void> _disconnectByHold() async {
    if (_connectedDevice == null) return;
    unawaited(HapticFeedback.heavyImpact());
    unawaited(relay.sendHaptic(1));
    await disconnect();
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

  // The pendant image is the disconnect gesture (hold), the switch under the
  // minutes chip owns capture, and the hero owns the single connection
  // indicator, so the main-screen DEVICE section only surfaces what those
  // cannot: the list of nearby pendants to pair with, and the last error.
  List<Widget> _deviceTiles(
    DeviceConnectionPhase phase,
    bool connected,
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
      if (!connected)
        for (final found in devices)
          _PaperTile(
            key: Key('companion_connect_${found.id}'),
            icon: Icons.watch_outlined,
            title: found.name,
            detail: [
              if (found.systemConnected) 'Already connected',
              if (found.signalStrength case final signal?) '$signal dBm',
              if (found.batteryLevel case final battery?) '$battery% battery',
            ].join(' · '),
            trailing: const _RowChevron(icon: Icons.add_circle_outline_rounded),
            onTap: phase == DeviceConnectionPhase.connecting
                ? null
                : () => connect(found),
          ),
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

  String _captureHint(bool connected, bool capturing) {
    if (!connected) return 'Reconnect to control your Omi';
    return capturing
        ? 'Capturing · Hold the pendant to disconnect'
        : 'Capture is off · Hold the pendant to disconnect';
  }

  @override
  Widget build(BuildContext context) {
    final phase = _phase;
    final device = snapshot?.device;
    final connected = _connectedDevice != null;
    final capturing = widget.services.deviceAudio.active;
    final lastError = error ?? widget.services.deviceAudio.lastError;
    final capturedMs = widget.transcripts.fold<int>(
      0,
      (sum, delta) => sum + math.max(0, delta.endMs - delta.startMs),
    );
    final busy =
        phase == DeviceConnectionPhase.scanning ||
        phase == DeviceConnectionPhase.connecting ||
        phase == DeviceConnectionPhase.disconnecting;
    // The pendant image reaches the very top edge past the notch, so the whole
    // page is one scroll view and only the hero fades/blurs as it scrolls off.
    final content = <Widget>[
      _LiveTranscriptStrip(
        connected: connected,
        capturing: capturing,
        interimText: widget.interimText,
        latestFinal: widget.transcripts.isEmpty
            ? null
            : widget.transcripts.first.text,
      ),
      if (!widget.previewMode &&
          widget.services.productionReady &&
          widget.services.currents != null)
        _MobileTasksSection(currents: widget.services.currents!),
      if (_update case final release?) ...[
        const SizedBox(height: _sectionGap),
        _UpdateCta(
          release: release,
          onOpen: () => _open(Uri.parse(release.url)),
          onDismiss: () => unawaited(_dismissUpdate(release)),
        ),
      ],
      const SizedBox(height: _sectionGap),
      const _SectionLabel('DEVICE'),
      ..._withGaps(_deviceTiles(phase, connected, lastError)),
      if (_desktopNoticeDismissed == false) ...[
        const SizedBox(height: _sectionGap),
        _DesktopCta(
          onOpen: () {
            _open(Uri.parse(desktopDownloadUrl));
            unawaited(_dismissDesktopNotice());
          },
          onDismiss: () => unawaited(_dismissDesktopNotice()),
        ),
      ],
      const SizedBox(height: _sectionGap),
      const _SectionLabel('CONVERSATIONS'),
      ..._withGaps(_transcriptTiles()),
      const SizedBox(height: 4),
    ];
    final body = CustomScrollView(
      key: const Key('companion_page_sections'),
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: _FadingHero(
            scrollOffset: _scrollOffset,
            child: _PendantHero(
              deviceName: device?.name,
              phaseLabel: _phaseLabel(phase),
              connected: connected,
              capturing: capturing,
              batteryLevel: connected ? device?.batteryLevel : null,
              capturedMinutes: (capturedMs / 60000).ceil(),
              hint: _captureHint(connected, capturing),
              busy: busy,
              captureEnabled: _captureEnabled,
              onCaptureChanged: widget.previewMode ? null : _setCaptureEnabled,
              onReconnect: () => unawaited(reconnect()),
              onHoldPendant: connected
                  ? () => unawaited(_disconnectByHold())
                  : null,
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          sliver: SliverList(
            key: const Key('companion_session_list'),
            delegate: SliverChildListDelegate(content),
          ),
        ),
      ],
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
    // The sheet's own surface is drawn inside the draggable child, so the
    // modal itself stays transparent: a DraggableScrollableSheet always fills
    // the bounded height it is given, and a coloured modal background would
    // paint the whole screen behind it.
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        elevation: 0,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) => _SettingsSheet(
          services: widget.services,
          previewMode: widget.previewMode,
          rememberedDeviceId: () => rememberedDeviceId,
          connectedDevice: () => _connectedDevice,
          capturing: () => widget.services.deviceAudio.active,
          segmentCount: () => widget.transcripts.length,
          onForget: forget,
          onDisconnect: disconnect,
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
          const SizedBox(height: _sectionGap),
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
                trailing: const _RowChevron(
                  icon: Icons.check_circle_outline_rounded,
                ),
                onTap: () => unawaited(currents.dismiss(task.item.id)),
              ),
          ]),
        ],
      );
    },
  );
}

List<Widget> _withGaps(List<Widget> tiles) => [
  for (final tile in tiles) ...[const SizedBox(height: _tileGap), tile],
];

String _codecLabel(DeviceAudioCodec codec) => switch (codec) {
  DeviceAudioCodec.pcm8 => 'PCM 8 kHz',
  DeviceAudioCodec.pcm16 => 'PCM 16 kHz',
  DeviceAudioCodec.opus => 'Opus 16 kHz',
  DeviceAudioCodec.opusFs320 => 'Opus 16 kHz (fs320)',
  DeviceAudioCodec.unknown => 'Unknown',
};

// The technical diagnostics moved off the main screen: audio codec, firmware
// version, hardware revision, model number, segment count, and the raw capture
// state. Read once from the connected device when the subpage opens.
class _DeveloperOptionsPage extends StatelessWidget {
  const _DeveloperOptionsPage({
    required this.device,
    required this.capturing,
    required this.segmentCount,
  });

  final RelayDevice? device;
  final bool capturing;
  final int segmentCount;

  @override
  Widget build(BuildContext context) {
    final dark = _darkMode(context);
    final device = this.device;
    return Scaffold(
      key: const Key('companion_developer_options_page'),
      backgroundColor: dark ? _inkSheet : _paper,
      appBar: AppBar(
        backgroundColor: dark ? _inkSheet : _paper,
        foregroundColor: _pageInk(context),
        elevation: 0,
        title: const Text('Developer options'),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          children: [
            const _SectionLabel('DIAGNOSTICS'),
            ..._withGaps([
              if (device == null)
                const _PaperTile(
                  icon: Icons.bluetooth_disabled_rounded,
                  title: 'No device connected',
                  detail: 'Connect your pendant to read firmware details.',
                )
              else ...[
                _PaperTile(
                  key: const Key('companion_dev_codec_tile'),
                  icon: Icons.graphic_eq_rounded,
                  title: 'Audio codec',
                  detail: _codecLabel(device.audioCodec),
                ),
                _PaperTile(
                  key: const Key('companion_dev_firmware_tile'),
                  icon: Icons.memory_rounded,
                  title: 'Firmware version',
                  detail: device.firmwareRevision ?? 'Not reported',
                ),
                _PaperTile(
                  key: const Key('companion_dev_hardware_tile'),
                  icon: Icons.developer_board_rounded,
                  title: 'Hardware revision',
                  detail: device.hardwareRevision ?? 'Not reported',
                ),
                _PaperTile(
                  key: const Key('companion_dev_model_tile'),
                  icon: Icons.qr_code_2_rounded,
                  title: 'Model number',
                  detail: device.modelNumber ?? 'Not reported',
                ),
                if (device.signalStrength case final signal?)
                  _PaperTile(
                    key: const Key('companion_dev_signal_tile'),
                    icon: Icons.network_check_rounded,
                    title: 'Signal',
                    detail: '$signal dBm',
                  ),
              ],
              _PaperTile(
                key: const Key('companion_dev_segments_tile'),
                icon: Icons.format_list_numbered_rounded,
                title: 'Segments captured',
                detail: '$segmentCount',
              ),
              _PaperTile(
                key: const Key('companion_dev_capture_tile'),
                icon: capturing
                    ? Icons.fiber_manual_record_rounded
                    : Icons.pause_circle_outline_rounded,
                iconColor: capturing ? _coral : null,
                title: 'Capture state',
                detail: capturing ? 'Live' : 'Idle',
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

// Blurs and fades the hero as the page scrolls: only this widget reacts to the
// scroll offset, so the rest of the page scrolls without fading. Increasing
// blur (ImageFiltered) pairs with decreasing opacity tied to scroll position.
class _FadingHero extends StatelessWidget {
  const _FadingHero({required this.scrollOffset, required this.child});

  static const _fadeDistance = 220.0;
  static const _maxBlur = 9.0;

  final ValueListenable<double> scrollOffset;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: scrollOffset,
    child: child,
    builder: (context, offset, child) {
      final progress = (offset / _fadeDistance).clamp(0.0, 1.0);
      final sigma = progress * _maxBlur;
      final hero = Opacity(
        key: const Key('companion_hero_fade'),
        opacity: 1 - progress,
        child: child,
      );
      if (sigma <= 0.01) return hero;
      return ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: hero,
      );
    },
  );
}

class _PendantHero extends StatefulWidget {
  const _PendantHero({
    required this.deviceName,
    required this.phaseLabel,
    required this.connected,
    required this.capturing,
    required this.batteryLevel,
    required this.capturedMinutes,
    required this.hint,
    required this.busy,
    required this.captureEnabled,
    required this.onCaptureChanged,
    required this.onReconnect,
    required this.onHoldPendant,
  });

  final String? deviceName;
  final String phaseLabel;
  final bool connected;
  final bool capturing;
  final int? batteryLevel;
  final int capturedMinutes;
  final String hint;
  final bool busy;
  final bool captureEnabled;
  final ValueChanged<bool>? onCaptureChanged;
  final VoidCallback onReconnect;
  final VoidCallback? onHoldPendant;

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
    final capturing = widget.capturing;
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
    final pendantStack = Stack(
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
        // Capture-on ring: a subtle blue halo around the pendant while audio
        // is streaming, mirroring the LED's capture-blue semantics.
        if (capturing)
          Positioned(
            top: pendantWidth * .1,
            child: IgnorePointer(
              child: Container(
                key: const Key('companion_capture_ring'),
                width: pendantWidth * .82,
                height: pendantWidth * .82,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _stateBlue.withValues(alpha: .55),
                    width: 3,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _stateBlue.withValues(alpha: .3),
                      blurRadius: 26,
                      spreadRadius: 2,
                    ),
                  ],
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
    );
    return Column(
      children: [
        Align(
          child: Semantics(
            button: connected,
            label: connected ? 'Hold to disconnect the pendant' : null,
            child: GestureDetector(
              key: const Key('companion_pendant_tap'),
              behavior: HitTestBehavior.opaque,
              onLongPress: widget.onHoldPendant,
              child: pendantStack,
            ),
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
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                    color: _pageInk(context),
                  ),
                ),
              ),
              const SizedBox(height: 3),
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
                const SizedBox(height: 10),
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
              const SizedBox(height: 5),
              Text(
                widget.hint,
                key: const Key('companion_pendant_hint'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: capturing
                      ? Color.lerp(_pageInkSoft(context), _stateBlue, .5)
                      : _pageInkSoft(context),
                ),
              ),
              if (widget.batteryLevel case final battery?)
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Semantics(
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
                ),
              // Tight gap so the minutes chip sits directly under the battery
              // percentage — the only stat shown on the main screen.
              if (connected) ...[
                const SizedBox(height: 5),
                _MinutesChip(minutes: widget.capturedMinutes),
              ],
              // The capture switch lives directly under the minutes chip: it
              // is the only control for a stream that is otherwise always on
              // while the pendant is connected.
              const SizedBox(height: 5),
              _CaptureToggle(
                enabled: widget.captureEnabled,
                capturing: capturing,
                connected: connected,
                onChanged: widget.onCaptureChanged,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CaptureToggle extends StatelessWidget {
  const _CaptureToggle({
    required this.enabled,
    required this.capturing,
    required this.connected,
    required this.onChanged,
  });

  final bool enabled;
  final bool capturing;
  final bool connected;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final active = capturing || (enabled && connected);
    return Semantics(
      container: true,
      label: 'Capture',
      child: Builder(
        builder: (context) => DecoratedBox(
          key: const Key('companion_capture_toggle'),
          decoration: BoxDecoration(
            color: _surface,
            border: Border.all(
              color: active ? _stateBlue.withValues(alpha: .4) : _hairline,
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  active ? Icons.graphic_eq_rounded : Icons.mic_off_rounded,
                  size: 15,
                  color: active ? _stateBlue : _inkSoft,
                ),
                const SizedBox(width: 6),
                Text(
                  enabled ? 'Capture on' : 'Capture off',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _ink,
                  ),
                ),
                const SizedBox(width: 4),
                Transform.scale(
                  scale: .78,
                  child: Switch(
                    key: const Key('companion_capture_switch'),
                    value: enabled,
                    onChanged: onChanged,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MinutesChip extends StatelessWidget {
  const _MinutesChip({required this.minutes});

  final int minutes;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$minutes minutes transcribed',
    excludeSemantics: true,
    child: DecoratedBox(
      key: const Key('companion_stat_minutes'),
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _hairline),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.graphic_eq_rounded, size: 15, color: _inkSoft),
            const SizedBox(width: 6),
            Text(
              '$minutes min transcribed',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _ink,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// The live "what you're saying" transcript, rendered directly under the hero
// and updating from the native transcript deltas as the user speaks. Interim
// text is shown while speaking; once a segment finalizes it moves into the
// session list below and this strip shows the latest final line.
class _LiveTranscriptStrip extends StatelessWidget {
  const _LiveTranscriptStrip({
    required this.connected,
    required this.capturing,
    required this.interimText,
    required this.latestFinal,
  });

  final bool connected;
  final bool capturing;
  final String interimText;
  final String? latestFinal;

  @override
  Widget build(BuildContext context) {
    if (!connected && interimText.isEmpty && latestFinal == null) {
      return const SizedBox.shrink();
    }
    final interim = interimText.trim().isNotEmpty;
    final text = interim
        ? interimText
        : (latestFinal ??
              (capturing
                  ? 'Listening…'
                  : 'Turn capture on to '
                        'start listening.'));
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: DecoratedBox(
        key: const Key('companion_live_transcript'),
        decoration: BoxDecoration(
          color: _surface,
          border: Border.all(
            color: interim ? _stateBlue.withValues(alpha: .4) : _hairline,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                interim || capturing
                    ? Icons.graphic_eq_rounded
                    : Icons.mic_none_rounded,
                size: 18,
                color: interim ? _stateBlue : _inkSoft,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    color: interim ? _ink : _inkSoft,
                    fontSize: 14,
                    height: 1.4,
                    fontStyle: interim ? FontStyle.normal : FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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

// Trailing affordance for a row whose whole surface is the tap target. It is
// deliberately an Icon and not an IconButton: the row itself carries the
// gesture, so a second, smaller hit target on the right would only compete
// with it.
class _RowChevron extends StatelessWidget {
  const _RowChevron({this.icon = Icons.chevron_right_rounded, this.color});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      Icon(icon, size: 20, color: color ?? _inkSoft);
}

class _PaperTile extends StatelessWidget {
  const _PaperTile({
    required this.icon,
    required this.title,
    required this.detail,
    this.trailing,
    this.iconColor,
    this.onTap,
    super.key,
  });

  static final BorderRadius radius = BorderRadius.circular(18);

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String detail;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _hairline),
      borderRadius: radius,
    ),
    child: Material(
      type: MaterialType.transparency,
      child: ListTile(
        // The entire row is the button; nothing on the right is separately
        // tappable, so the touch target always spans the full width.
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: radius),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
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
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            detail,
            style: const TextStyle(color: _inkSoft, fontSize: 13, height: 1.35),
          ),
        ),
        trailing: trailing,
      ),
    ),
  );
}

// A warm banner row that behaves like every other row: the whole card opens
// the link, and dismissing lives on its own full-width control underneath.
class _BannerCta extends StatelessWidget {
  const _BannerCta({
    required this.tileKey,
    required this.dismissKey,
    required this.icon,
    required this.title,
    required this.detail,
    required this.dismissLabel,
    required this.onOpen,
    required this.onDismiss,
  });

  final Key tileKey;
  final Key dismissKey;
  final IconData icon;
  final String title;
  final String detail;
  final String dismissLabel;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DecoratedBox(
        key: tileKey,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xffddf2e8), Color(0xffffe9d8)],
          ),
          border: Border.all(color: _hairline),
          borderRadius: _PaperTile.radius,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: ListTile(
            onTap: onOpen,
            shape: RoundedRectangleBorder(borderRadius: _PaperTile.radius),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 2,
            ),
            leading: Icon(icon, color: _teal),
            title: Text(
              title,
              style: const TextStyle(
                color: _ink,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                detail,
                style: const TextStyle(
                  color: _inkSoft,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ),
            trailing: const _RowChevron(),
          ),
        ),
      ),
      SizedBox(
        height: 30,
        child: TextButton(
          key: dismissKey,
          onPressed: onDismiss,
          style: TextButton.styleFrom(
            foregroundColor: _inkSoft,
            padding: EdgeInsets.zero,
            textStyle: const TextStyle(fontSize: 12.5),
          ),
          child: Text(dismissLabel),
        ),
      ),
    ],
  );
}

class _DesktopCta extends StatelessWidget {
  const _DesktopCta({required this.onOpen, required this.onDismiss});

  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => _BannerCta(
    tileKey: const Key('companion_desktop_notice_tile'),
    dismissKey: const Key('companion_desktop_notice_dismiss'),
    icon: Icons.desktop_mac_outlined,
    title: 'Install the Omi desktop app',
    detail: 'Omi learns more about you from your Mac or Windows PC.',
    dismissLabel: 'Not now',
    onOpen: onOpen,
    onDismiss: onDismiss,
  );
}

class _UpdateCta extends StatelessWidget {
  const _UpdateCta({
    required this.release,
    required this.onOpen,
    required this.onDismiss,
  });

  final MobileRelease release;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => _BannerCta(
    tileKey: const Key('companion_update_tile'),
    dismissKey: const Key('companion_update_dismiss'),
    icon: Icons.system_update_alt_rounded,
    title: 'Update to ${release.version}',
    detail: 'A newer Omi for your phone is ready to install.',
    dismissLabel: 'Later',
    onOpen: onOpen,
    onDismiss: onDismiss,
  );
}

// Owns the rename field's controller so it outlives the dialog's exit
// transition; disposing it inline as soon as showDialog resolves tears the
// controller out from under the still-animating route.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename device'),
    content: TextField(
      key: const Key('companion_rename_field'),
      controller: _controller,
      autofocus: true,
      maxLength: 20,
      decoration: const InputDecoration(labelText: 'Device name'),
      onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        key: const Key('companion_rename_confirm'),
        onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
        child: const Text('Save'),
      ),
    ],
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.services,
    required this.previewMode,
    required this.rememberedDeviceId,
    required this.connectedDevice,
    required this.capturing,
    required this.segmentCount,
    required this.onForget,
    required this.onDisconnect,
  });

  final AppServices services;
  final bool previewMode;
  final String? Function() rememberedDeviceId;
  final RelayDevice? Function() connectedDevice;
  final bool Function() capturing;
  final int Function() segmentCount;
  final Future<void> Function() onForget;
  final Future<void> Function() onDisconnect;

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

  Future<void> _rename() async {
    final device = widget.connectedDevice();
    if (device == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _RenameDialog(initialName: device.name),
    );
    if (name == null || name.isEmpty) return;
    final ok = await widget.services.deviceRelay.renameDevice(name);
    if (!mounted) return;
    setState(() {});
    if (!ok) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Renaming is not supported on this firmware.'),
        ),
      );
    }
  }

  Future<void> _sleep() async {
    final confirmed = await _confirm(
      title: 'Put Omi to sleep?',
      message: 'This powers off your pendant. Press its button to wake it.',
      action: 'Sleep',
      confirmKey: const Key('companion_sleep_confirm'),
    );
    if (!confirmed) return;
    final ok = await widget.services.deviceRelay.sleepDevice();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Sleep is not supported on this '
            'firmware.',
          ),
        ),
      );
    }
  }

  void _openDeveloperOptions() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (routeContext) => _DeveloperOptionsPage(
            device: widget.connectedDevice(),
            capturing: widget.capturing(),
            segmentCount: widget.segmentCount(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final remembered = widget.rememberedDeviceId();
    final connected = widget.connectedDevice() != null;
    final supportsRename = widget.services.deviceRelay.supportsRename;
    final dark = _darkMode(context);
    // DraggableScrollableSheet links the list's scroll position to the sheet
    // extent, so a downward drag while the list sits at offset 0 collapses the
    // sheet to its minimum extent — which is what pops the modal route. A
    // plain scrollable child swallows that drag and leaves the sheet stuck.
    return DraggableScrollableSheet(
      key: const Key('companion_settings_draggable'),
      expand: false,
      snap: true,
      initialChildSize: .92,
      minChildSize: 0,
      maxChildSize: .92,
      builder: (context, scrollController) => DecoratedBox(
        decoration: BoxDecoration(
          color: dark ? _inkSheet : _paper,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: ListView(
          key: const Key('companion_settings_sheet'),
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          children: [
            Center(
              child: Container(
                key: const Key('companion_settings_grabber'),
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: _pageInkSoft(context).withValues(alpha: .35),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const _SectionLabel('SETTINGS'),
            ..._withGaps(
              _MobileSettingsSection.tiles(
                context,
                services: widget.services,
                previewMode: widget.previewMode,
              ),
            ),
            if (remembered != null || connected) ...[
              const SizedBox(height: _sectionGap),
              const _SectionLabel('DEVICE'),
              ..._withGaps([
                if (connected)
                  _PaperTile(
                    key: const Key('companion_settings_disconnect'),
                    icon: Icons.link_off_rounded,
                    title: 'Disconnect',
                    detail: 'Disconnect the pendant but keep it paired.',
                    trailing: const _RowChevron(),
                    onTap: () => unawaited(
                      widget.onDisconnect().then((_) {
                        if (mounted) setState(() {});
                      }),
                    ),
                  ),
                if (connected && supportsRename)
                  _PaperTile(
                    key: const Key('companion_rename_device'),
                    icon: Icons.drive_file_rename_outline_rounded,
                    title: 'Rename device',
                    detail: 'Change the name your pendant advertises.',
                    trailing: const _RowChevron(),
                    onTap: () => unawaited(_rename()),
                  ),
                if (connected)
                  _PaperTile(
                    key: const Key('companion_sleep_device'),
                    icon: Icons.bedtime_outlined,
                    title: 'Sleep now',
                    detail: 'Power off the pendant until you wake it.',
                    trailing: const _RowChevron(),
                    onTap: () => unawaited(_sleep()),
                  ),
                if (remembered != null)
                  _PaperTile(
                    key: const Key('companion_remembered_tile'),
                    icon: Icons.history_rounded,
                    title: 'Remembered device',
                    detail: remembered,
                    trailing: const _RowChevron(
                      icon: Icons.delete_outline_rounded,
                    ),
                    onTap: () => unawaited(
                      widget.onForget().then((_) {
                        if (mounted) setState(() {});
                      }),
                    ),
                  ),
                _PaperTile(
                  key: const Key('companion_developer_options'),
                  icon: Icons.code_rounded,
                  title: 'Developer options',
                  detail: 'Firmware, hardware, codec, and capture diagnostics.',
                  trailing: const _RowChevron(),
                  onTap: _openDeveloperOptions,
                ),
                if (remembered != null)
                  _PaperTile(
                    key: const Key('companion_reset_pendant'),
                    icon: Icons.restart_alt_rounded,
                    iconColor: _coral,
                    title: 'Reset pendant',
                    detail: 'Disconnect and forget this pendant.',
                    trailing: const _RowChevron(color: _coral),
                    onTap: () => unawaited(_resetPendant()),
                  ),
              ]),
            ],
            const SizedBox(height: _sectionGap),
            const _SectionLabel('CALENDAR & REMINDERS'),
            const SizedBox(height: _tileGap),
            // The EventKit tile is shared with the desktop settings window,
            // where a surrounding group paints the surface. On the phone it
            // stands alone, so give it the same paper card every other row on
            // this sheet has.
            _PaperCard(
              child: EventKitProactiveSyncTile(
                key: const Key('companion_eventkit_proactive_sync'),
                previewMode: widget.previewMode,
              ),
            ),
            if (!widget.previewMode) ...[
              const SizedBox(height: _sectionGap),
              const _SectionLabel('DANGER ZONE'),
              ..._withGaps([
                _PaperTile(
                  key: const Key('companion_delete_account'),
                  icon: Icons.delete_forever_rounded,
                  iconColor: _coral,
                  title: 'Delete account',
                  detail: 'Permanently delete your account and data.',
                  trailing: const _RowChevron(color: _coral),
                  onTap: _deleting ? null : () => unawaited(_deleteAccount()),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

// The warm-paper card every mobile row sits on, without the row layout — for
// tiles that bring their own content (the shared EventKit switch row).
class _PaperCard extends StatelessWidget {
  const _PaperCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _hairline),
      borderRadius: _PaperTile.radius,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: child,
    ),
  );
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

  // Processing consent is recorded once during onboarding and re-established
  // automatically by the home screen when the receipt goes missing, so the
  // phone shows the account, not the paperwork: no consent tile, and no
  // transcription-route tile either.
  @override
  Widget build(BuildContext context) {
    final auth = services.auth;
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        final session = auth.snapshot.session;
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
            ),
            if (session != null && !previewMode) ...[
              const SizedBox(height: _tileGap),
              _PaperTile(
                key: const Key('companion_sign_out'),
                icon: Icons.logout_rounded,
                title: 'Sign out',
                detail: 'Leave this account on this phone.',
                trailing: const _RowChevron(),
                onTap: () => unawaited(auth.signOut()),
              ),
            ],
          ],
        );
      },
    );
  }
}
