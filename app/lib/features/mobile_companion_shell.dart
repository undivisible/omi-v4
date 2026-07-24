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
import '../ui/burst_glow.dart';
import '../ui/scroll_edge_fade.dart';
import 'capture_notifier.dart';
import 'firmware_install.dart';
import 'firmware_update_check.dart';
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
    this.firmwareChecker,
    this.firmwareDownloader,
    this.firmwareFlasher,
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
  final FirmwareUpdateChecker? firmwareChecker;
  final FirmwareDownloader? firmwareDownloader;
  final FirmwareFlasher? firmwareFlasher;
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
              firmwareChecker: widget.firmwareChecker,
              firmwareDownloader: widget.firmwareDownloader,
              firmwareFlasher: widget.firmwareFlasher,
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
    this.firmwareChecker,
    this.firmwareDownloader,
    this.firmwareFlasher,
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
  final FirmwareUpdateChecker? firmwareChecker;
  final FirmwareDownloader? firmwareDownloader;
  final FirmwareFlasher? firmwareFlasher;
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
  // Turns false once a capture-LED write has been refused, which is what old
  // firmware without 19b10015 does. The switch keeps working — only the claim
  // that the pendant light follows it is withdrawn.
  bool _captureLedSupported = true;
  // A connect this page started already brings capture up on its own, so the
  // snapshot that lands mid-connect must not race it with a second attempt.
  bool _connectInFlight = false;
  MobileRelease? _update;
  FirmwareRelease? _firmwareUpdate;
  // The firmware feed is read once per connected pendant, not once per
  // snapshot: battery notifications alone would otherwise poll GitHub.
  bool _firmwareChecked = false;
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
      _maybeCheckFirmware();
    });
    // Capture starts and stops without anyone touching the switch — it comes up
    // with the connection and ends when the link drops — and `active` is a
    // plain getter the hero can only sample while it happens to be rebuilding.
    // Without this listener the auto-connect path renders capture as off for
    // the whole session and never writes the pendant LED.
    widget.services.deviceAudio.activeListenable.addListener(_captureChanged);
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

  // The firmware notice only exists for a pendant that can actually take an
  // update over Bluetooth: the SMP service has to be there, and the pendant has
  // to have told us which revision it runs.
  void _maybeCheckFirmware() {
    if (widget.previewMode || _firmwareChecked) return;
    final device = _connectedDevice;
    if (device == null || !relay.dfuSupported) return;
    _firmwareChecked = true;
    unawaited(_checkForFirmwareUpdate(device));
  }

  Future<void> _checkForFirmwareUpdate(RelayDevice device) async {
    FirmwareRelease? release;
    try {
      release = await (widget.firmwareChecker ?? FirmwareUpdateChecker()).check(
        installedRevision: device.firmwareRevision,
        target: device.modelNumber,
      );
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _firmwareUpdate = release);
  }

  Future<void> _dismissFirmwareUpdate(FirmwareRelease release) async {
    setState(() => _firmwareUpdate = null);
    await (widget.firmwareChecker ?? FirmwareUpdateChecker()).dismiss(release);
  }

  void _openFirmwareUpdate([FirmwareRelease? release]) => unawaited(
    _pushFirmwareUpdate(
      context,
      services: widget.services,
      device: () => _connectedDevice,
      capturing: () => widget.services.deviceAudio.active,
      checker: widget.firmwareChecker ?? FirmwareUpdateChecker(),
      downloader: widget.firmwareDownloader ?? HttpFirmwareDownloader(),
      flasher: widget.firmwareFlasher ?? McuMgrFirmwareFlasher(),
      openLink: widget.openLink ?? _openExternalLink,
      release: release,
    ).then((_) {
      // A finished install leaves the pendant on a new revision, so the notice
      // has to be re-derived rather than left standing.
      if (!mounted) return;
      setState(() => _firmwareUpdate = null);
      _firmwareChecked = false;
      _maybeCheckFirmware();
    }),
  );

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
    if (active == _captureEnabled) {
      // Already matched, but a reconnect resets the pendant's own LED state, so
      // re-assert it instead of leaving the light stale.
      unawaited(_reflectCaptureOnPendant(active));
      return;
    }
    _syncingCapture = true;
    unawaited(
      _setCapture(_captureEnabled).whenComplete(() => _syncingCapture = false),
    );
  }

  void _captureChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_reflectCaptureOnPendant(widget.services.deviceAudio.active));
  }

  // Mirrors the app's capture state onto the pendant LED (19b10015). Every
  // capture transition runs through here, so the light follows a stream that
  // started on its own just as well as one the switch started.
  Future<void> _reflectCaptureOnPendant(bool capturing) async {
    if (widget.previewMode || _connectedDevice == null) return;
    final written = await relay.writeCaptureLed(capturing);
    if (!mounted) return;
    final supported = written && relay.captureLedSupported;
    if (supported == _captureLedSupported) return;
    setState(() => _captureLedSupported = supported);
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
    widget.services.deviceAudio.activeListenable.removeListener(
      _captureChanged,
    );
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
        // capture-state characteristic; a no-op on firmware without it. The
        // write itself is driven by the capture-state listener, so that the
        // light follows every transition and not only this one.
        unawaited(widget.captureNotifier.captureStopped());
      } else if (device != null) {
        await widget.services.connectDevice(device.id);
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

  // Tapping the pendant image is the capture control: connected it flips
  // capture, disconnected it reconnects. One image, one tap, so the gesture
  // never means two things at once.
  void _tapPendant() {
    if (_connectedDevice == null) {
      unawaited(reconnect());
      return;
    }
    _setCaptureEnabled(!_captureEnabled);
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

  String _captureHint(bool connected, bool capturing, bool busy) {
    if (busy) return 'Connecting…';
    if (!connected) return 'Tap the pendant to reconnect';
    return capturing
        ? 'Tap to stop · Hold to disconnect'
        : 'Tap to start capturing · Hold to disconnect';
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
    final deviceTiles = _deviceTiles(phase, connected, lastError);
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
      // A connected pendant with nothing to pair and nothing wrong leaves the
      // DEVICE section empty, and a lone heading over blank space is what put
      // the yawning gap above the desktop invitation.
      if (deviceTiles.isNotEmpty) ...[
        const SizedBox(height: _sectionGap),
        const _SectionLabel('DEVICE'),
        ..._withGaps(deviceTiles),
      ],
      // The pendant notice shares the desktop notice's slot and its component:
      // one full-row banner card, whole row tappable, dismissal persisted, and
      // present only when there is genuinely something to do. A waiting
      // firmware update outranks the desktop invitation.
      if (_firmwareUpdate case final release?) ...[
        const SizedBox(height: _sectionGap),
        _FirmwareCta(
          release: release,
          onOpen: () => _openFirmwareUpdate(release),
          onDismiss: () => unawaited(_dismissFirmwareUpdate(release)),
        ),
      ],
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
              hint: _captureHint(connected, capturing, busy),
              busy: busy,
              ledSupported: _captureLedSupported,
              onTapPendant: widget.previewMode ? null : _tapPendant,
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
        ScrollEdgeFade(child: body),
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
          firmwareChecker: widget.firmwareChecker,
          firmwareDownloader: widget.firmwareDownloader,
          firmwareFlasher: widget.firmwareFlasher,
          openLink: widget.openLink ?? _openExternalLink,
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
    required this.dfuSupported,
  });

  final RelayDevice? device;
  final bool capturing;
  final int segmentCount;
  final bool dfuSupported;

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
                // The update affordance is hidden, not disabled, when the
                // running image has no SMP service — so say why here rather
                // than leaving its absence unexplained.
                _PaperTile(
                  key: const Key('companion_dev_dfu_tile'),
                  icon: Icons.system_update_alt_rounded,
                  title: 'Bluetooth firmware update',
                  detail: dfuSupported
                      ? 'Available: this pendant advertises the MCUboot OTA '
                            '(SMP) service.'
                      : 'Unavailable: this firmware was built without the '
                            'MCUboot OTA (SMP) service, so updates have to go '
                            'over USB (nRF Connect Programmer or a J-Link) '
                            'once. After that, updating from the app works.',
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

// Bridges the install flow to the live relay: the installer asks for the
// pendant's state as it goes, and the answers have to keep coming after the
// app has let go of the connection, which is when the shell's own view of the
// device goes null.
final class _RelayFirmwareInstallHost implements FirmwareInstallHost {
  _RelayFirmwareInstallHost({
    required this.services,
    required this.device,
    required this.isCapturing,
  });

  final AppServices services;
  final RelayDevice? Function() device;
  final bool Function() isCapturing;

  String? _pinnedId;
  String? _pinnedRevision;
  int? _pinnedBattery;

  RelayDevice? get _live {
    final live = device();
    if (live != null) {
      _pinnedId = live.id;
      _pinnedRevision = live.firmwareRevision ?? _pinnedRevision;
      _pinnedBattery = live.batteryLevel ?? _pinnedBattery;
    }
    return live;
  }

  @override
  String? get deviceId => _live?.id ?? _pinnedId;

  @override
  String? get installedRevision => _live?.firmwareRevision ?? _pinnedRevision;

  @override
  int? get batteryLevel => _live?.batteryLevel ?? _pinnedBattery;

  @override
  bool get connected => _live != null;

  @override
  bool get dfuSupported => services.deviceRelay.dfuSupported;

  @override
  bool get capturing => isCapturing();

  @override
  Future<void> releaseLink() async {
    // Reads the getter first so the identifier is pinned before the relay
    // forgets the device.
    deviceId;
    await services.disconnectDevice();
  }

  @override
  Future<String?> reconnect() async {
    final id = deviceId;
    if (id == null) return null;
    final device = await services.connectDevice(id);
    _pinnedRevision = device.firmwareRevision ?? _pinnedRevision;
    return device.firmwareRevision;
  }
}

Future<void> _pushFirmwareUpdate(
  BuildContext context, {
  required AppServices services,
  required RelayDevice? Function() device,
  required bool Function() capturing,
  required FirmwareUpdateChecker checker,
  required FirmwareDownloader downloader,
  required FirmwareFlasher flasher,
  required LinkOpener openLink,
  FirmwareRelease? release,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (routeContext) => _FirmwareUpdatePage(
      host: _RelayFirmwareInstallHost(
        services: services,
        device: device,
        isCapturing: capturing,
      ),
      checker: checker,
      downloader: downloader,
      flasher: flasher,
      openLink: openLink,
      release: release,
    ),
  ),
);

// The pendant firmware update, end to end: detection, the pre-flight gate, the
// download, and the flash itself over SMP/mcumgr. `omi-cv1` runs MCUboot
// overwrite-only with downgrade prevention, so nothing here writes an image
// that is not strictly newer, and nothing writes a package whose bytes do not
// match what the release published — see `docs/mobile-firmware-dfu.md`.
class _FirmwareUpdatePage extends StatefulWidget {
  const _FirmwareUpdatePage({
    required this.host,
    required this.checker,
    required this.downloader,
    required this.flasher,
    required this.openLink,
    this.release,
  });

  final FirmwareInstallHost host;
  final FirmwareUpdateChecker checker;
  final FirmwareDownloader downloader;
  final FirmwareFlasher flasher;
  final LinkOpener openLink;

  /// Handed in when the home banner already found the release, so opening the
  /// screen from there does not re-query the feed before it can act.
  final FirmwareRelease? release;

  @override
  State<_FirmwareUpdatePage> createState() => _FirmwareUpdatePageState();
}

class _FirmwareUpdatePageState extends State<_FirmwareUpdatePage> {
  late bool _checking = widget.release == null;
  late FirmwareRelease? _release = widget.release;
  Object? _error;
  late final FirmwareInstaller _installer = FirmwareInstaller(
    host: widget.host,
    downloader: widget.downloader,
    flasher: widget.flasher,
  );

  @override
  void initState() {
    super.initState();
    _installer.addListener(_installerChanged);
    if (_checking) unawaited(_check());
  }

  @override
  void dispose() {
    _installer.removeListener(_installerChanged);
    _installer.dispose();
    super.dispose();
  }

  void _installerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _check() async {
    FirmwareRelease? release;
    Object? failure;
    try {
      release = await widget.checker.check(
        installedRevision: widget.host.installedRevision,
        target: _target,
      );
    } catch (error) {
      failure = error;
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _release = release;
      _error = failure;
    });
  }

  // The build target the release publishes per-package artifacts under. Read
  // from the device's model number, which is what the firmware reports over
  // DIS; a release with a single package matches regardless.
  String? get _target => widget.host is _RelayFirmwareInstallHost
      ? (widget.host as _RelayFirmwareInstallHost).device()?.modelNumber
      : null;

  FirmwareUpdateBlock get _block => firmwareUpdateBlock(
    connected: widget.host.connected,
    dfuSupported: widget.host.dfuSupported,
    capturing: widget.host.capturing,
    batteryLevel: widget.host.batteryLevel,
  );

  @override
  Widget build(BuildContext context) {
    final dark = _darkMode(context);
    final release = _release;
    final block = _block;
    final status = _installer.status;
    return Scaffold(
      key: const Key('companion_firmware_page'),
      backgroundColor: dark ? _inkSheet : _paper,
      appBar: AppBar(
        backgroundColor: dark ? _inkSheet : _paper,
        foregroundColor: _pageInk(context),
        elevation: 0,
        title: const Text('Firmware update'),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          children: [
            const _SectionLabel('PENDANT'),
            ..._withGaps([
              _PaperTile(
                key: const Key('companion_firmware_installed'),
                icon: Icons.memory_rounded,
                title: 'Installed',
                detail: widget.host.installedRevision ?? 'Not reported',
              ),
              if (_checking)
                const _PaperTile(
                  key: Key('companion_firmware_checking'),
                  icon: Icons.sync_rounded,
                  title: 'Checking for updates…',
                  detail: 'Reading the published firmware releases.',
                )
              else if (release == null)
                _PaperTile(
                  key: const Key('companion_firmware_up_to_date'),
                  icon: Icons.check_circle_outline_rounded,
                  title: _error == null
                      ? 'Up to date'
                      : 'Could not check for updates',
                  detail: _error == null
                      ? 'No newer firmware has been published.'
                      : '$_error',
                )
              else ...[
                _PaperTile(
                  key: const Key('companion_firmware_available'),
                  icon: Icons.system_update_alt_rounded,
                  title: 'Firmware ${release.version} available',
                  detail: release.assetName,
                  trailing: const _RowChevron(),
                  onTap: () =>
                      unawaited(widget.openLink(Uri.parse(release.url))),
                ),
                if (block != FirmwareUpdateBlock.none)
                  _PaperTile(
                    key: const Key('companion_firmware_block'),
                    icon: Icons.warning_amber_rounded,
                    iconColor: _coral,
                    title: 'Not ready to update',
                    detail: firmwareInstallBlockMessage(block),
                  ),
                if (status.phase != FirmwareInstallPhase.idle)
                  _FirmwareInstallCard(status: status),
                if (status.busy)
                  _PaperTile(
                    key: const Key('companion_firmware_abort'),
                    icon: Icons.stop_circle_outlined,
                    iconColor: _coral,
                    title: 'Stop the update',
                    detail: status.committed
                        ? 'Safe until the pendant reboots: the new image is '
                              'only swapped in once all of it has arrived.'
                        : 'Nothing has been written to your pendant yet.',
                    trailing: const _RowChevron(color: _coral),
                    onTap: _installer.abort,
                  )
                else if (block == FirmwareUpdateBlock.none)
                  _PaperTile(
                    key: const Key('companion_firmware_install'),
                    icon: Icons.bolt_rounded,
                    title: status.phase == FirmwareInstallPhase.installed
                        ? 'Installed'
                        : status.phase == FirmwareInstallPhase.failed
                        ? 'Try the update again'
                        : 'Install firmware ${release.version}',
                    detail: switch (release.sizeBytes) {
                      null =>
                        'Downloads the package, then writes it over Bluetooth.',
                      final size =>
                        '${(size / 1024).round()} KB · downloads, then writes '
                            'it over Bluetooth.',
                    },
                    trailing: const _RowChevron(),
                    onTap: status.phase == FirmwareInstallPhase.installed
                        ? null
                        : () => unawaited(_installer.install(release)),
                  ),
              ],
            ]),
          ],
        ),
      ),
    );
  }
}

// The one place an install reports itself: phase, real progress, and — when it
// fails — what to do next, so the flow never dead-ends.
class _FirmwareInstallCard extends StatelessWidget {
  const _FirmwareInstallCard({required this.status});

  final FirmwareInstallStatus status;

  String get _label => switch (status.phase) {
    FirmwareInstallPhase.idle => '',
    FirmwareInstallPhase.downloading =>
      'Downloading ${((status.progress ?? 0) * 100).round()}%',
    FirmwareInstallPhase.verifying => 'Verifying the package',
    FirmwareInstallPhase.preparing => 'Preparing your pendant',
    FirmwareInstallPhase.installing =>
      status.progress == null
          ? 'Installing'
          : 'Installing ${((status.progress ?? 0) * 100).round()}%',
    FirmwareInstallPhase.confirming => 'Confirming the new version',
    FirmwareInstallPhase.installed => 'Installed',
    FirmwareInstallPhase.failed => 'Update stopped',
  };

  @override
  Widget build(BuildContext context) => _PaperCard(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _label,
            key: const Key('companion_firmware_progress_label'),
            style: TextStyle(
              fontSize: 13,
              color: status.phase == FirmwareInstallPhase.failed
                  ? _coral
                  : _inkSoft,
            ),
          ),
          const SizedBox(height: 8),
          if (status.busy)
            LinearProgressIndicator(
              key: const Key('companion_firmware_progress'),
              value: status.progress,
              backgroundColor: _hairline,
              color: _teal,
            ),
          if (status.message case final message?) ...[
            if (status.busy) const SizedBox(height: 8),
            Text(
              message,
              key: const Key('companion_firmware_progress_message'),
              style: const TextStyle(
                fontSize: 13,
                color: _inkSoft,
                height: 1.35,
              ),
            ),
          ],
          if (status.recovery case final recovery?) ...[
            const SizedBox(height: 8),
            Text(
              recovery,
              key: const Key('companion_firmware_recovery'),
              style: const TextStyle(
                fontSize: 13,
                color: _inkSoft,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    ),
  );
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

// The pendant asset is cropped to its alpha bounds (1103×1287), so its aspect
// is the pendant's own and every hero measurement derives from it.
const _pendantAspect = 1287 / 1103;

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
    required this.ledSupported,
    required this.onTapPendant,
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
  final bool ledSupported;
  final VoidCallback? onTapPendant;
  final VoidCallback? onHoldPendant;

  @override
  State<_PendantHero> createState() => _PendantHeroState();
}

class _PendantHeroState extends State<_PendantHero>
    with TickerProviderStateMixin {
  late final AnimationController _sway = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  // While the pendant is connecting it breathes: the image itself pulses in
  // opacity, which is the busy signal now that the spinner beside it is gone.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  bool _animationsDisabled = false;
  // The image is the control now, so it has to answer the finger: held down it
  // dips in scale and opacity, exactly like a button would.
  bool _pressed = false;
  // Bumped on every disconnected → connected edge so the burst glow is a new
  // widget each time; it fires exactly once per instance by design.
  int _connectEpoch = 0;
  // Only a genuine connect edge mounts the burst, so an already-connected
  // pendant painting for the first time stays quiet, and once the burst has
  // decayed it unmounts and leaves nothing sitting around the pendant.
  bool _bursting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animationsDisabled = MediaQuery.disableAnimationsOf(context);
    if (_animationsDisabled) {
      _sway.stop();
      _pulse.stop();
    } else if (!_sway.isAnimating) {
      _sway.repeat();
    }
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _PendantHero old) {
    super.didUpdateWidget(old);
    if (widget.connected && !old.connected) {
      _connectEpoch += 1;
      _bursting = true;
    }
    if (widget.busy != old.busy) _syncPulse();
  }

  // The pulse only runs while connecting, and only when motion is allowed;
  // otherwise the image sits at full opacity.
  void _syncPulse() {
    if (widget.busy && !_animationsDisabled) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _sway.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animationsDisabled = _animationsDisabled;
    final width = MediaQuery.sizeOf(context).width;
    // Tuned against the asset's real content bounds: the pendant fills the
    // whole 1103×1287 image now, so the width is the pendant's width and the
    // height follows from its aspect rather than from a square canvas that was
    // a third empty.
    final pendantWidth = math.min(width * .5, 250.0);
    final pendantHeight = pendantWidth * _pendantAspect;
    final connected = widget.connected;
    final capturing = widget.capturing;
    final image = Image.asset(
      'assets/images/omi_pendant.png',
      key: const Key('companion_pendant_image'),
      width: pendantWidth,
      height: pendantHeight,
      fit: BoxFit.fitWidth,
      excludeFromSemantics: true,
    );
    // The pendant warms up rather than snapping: colour and opacity are two
    // continuous ramps over the same 0…1, so connecting fades and saturates the
    // image in and disconnecting runs the identical curve backwards. Fully
    // warm is the untouched asset, so the filter drops out entirely there.
    // While connecting, the pendant breathes in opacity; otherwise it sits
    // solid. This is the busy indicator now that the spinner is gone.
    Widget pulsing(Widget child) => widget.busy && !animationsDisabled
        ? AnimatedBuilder(
            animation: _pulse,
            builder: (context, inner) =>
                Opacity(opacity: .4 + _pulse.value * .6, child: inner),
            child: child,
          )
        : child;
    Widget pendantFor(double warmth) => warmth >= 1
        ? image
        : Opacity(
            key: const Key('companion_pendant_faded'),
            opacity: .35 + warmth * .65,
            child: ColorFiltered(
              colorFilter: ColorFilter.matrix(_saturationMatrix(warmth)),
              child: image,
            ),
          );
    final glowSize = pendantWidth * 2.2;
    final glowTop = pendantHeight * .82 - glowSize / 2;
    final pendantStack = Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        // The connect finale: the warm glow bursts outward once, keyed on the
        // connection so a later reconnect fires a fresh one. Skipped under
        // reduced motion, where a burst that cannot animate would only leave a
        // static blob behind the pendant.
        if (connected && _bursting && !animationsDisabled)
          Positioned(
            top: glowTop,
            child: OmiBurstGlow(
              key: ValueKey('companion_connect_burst_$_connectEpoch'),
              progress: .92,
              complete: true,
              baseDiameter: glowSize * .58,
              growth: 0,
              onBurstDone: () {
                if (mounted) setState(() => _bursting = false);
              },
            ),
          ),
        Positioned(
          top: glowTop,
          child: IgnorePointer(
            child: Container(
              key: const Key('companion_pendant_glow'),
              width: glowSize,
              height: glowSize,
              // A single warm halo, never tinted by connection state: the blue
              // ring that used to appear on connect is gone, and the burst
              // above carries the moment instead. It brightens a little once
              // warm, but keeps the same hue.
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    const Color(
                      0xfff2a78f,
                    ).withValues(alpha: connected ? .2 : .12),
                    const Color(
                      0xfff6c9a0,
                    ).withValues(alpha: connected ? .1 : .06),
                    const Color(0x00f2a78f),
                  ],
                  stops: const [0, .45, 1],
                ),
              ),
            ),
          ),
        ),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(end: connected ? 1 : 0),
          duration: animationsDisabled
              ? Duration.zero
              : const Duration(milliseconds: 520),
          curve: Curves.easeOutCubic,
          builder: (context, warmth, _) => AnimatedBuilder(
            animation: _sway,
            // Anchored to the top edge, which the layout above pins to the very
            // top of the screen: scaling about the centre would walk the
            // pendant down the page as it warms up.
            child: Transform.scale(
              scale: .965 + warmth * .035,
              alignment: Alignment.topCenter,
              child: pulsing(pendantFor(warmth)),
            ),
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
        ),
      ],
    );
    return Column(
      children: [
        Align(
          child: Semantics(
            button: true,
            label: connected
                ? (capturing
                      ? 'Stop capturing. Hold to disconnect the pendant'
                      : 'Start capturing. Hold to disconnect the pendant')
                : 'Reconnect the pendant',
            child: GestureDetector(
              key: const Key('companion_pendant_tap'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.busy ? null : widget.onTapPendant,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              onLongPress: widget.onHoldPendant,
              // Until the asset decodes the image lays out with no height at
              // all, and the pendant is now the only capture and reconnect
              // control, so its hit area must never collapse to nothing.
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: pendantHeight),
                child: AnimatedScale(
                  scale: _pressed ? .96 : 1,
                  duration: animationsDisabled
                      ? Duration.zero
                      : const Duration(milliseconds: 110),
                  curve: Curves.easeOut,
                  child: AnimatedOpacity(
                    opacity: _pressed ? .78 : 1,
                    duration: animationsDisabled
                        ? Duration.zero
                        : const Duration(milliseconds: 110),
                    child: pendantStack,
                  ),
                ),
              ),
            ),
          ),
        ),
        // A translate here would leave its own height behind and open a gap
        // under the last chip, so the copy is spaced by real layout instead.
        SizedBox(height: pendantWidth * .06),
        Column(
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
            // Hidden while connecting: the status line above already says so,
            // and the hint would only repeat "Connecting…" underneath it.
            if (!widget.busy) ...[
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
            ],
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
            if (connected && !widget.ledSupported) ...[
              const SizedBox(height: 5),
              const Text(
                'Your pendant light stays as it is: this firmware cannot be '
                'told about capture.',
                key: Key('companion_capture_led_unsupported'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: _inkSoft, height: 1.3),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

// Rec. 709 luminance weights, the same ones the fully desaturated pendant used
// before it learned to fade: [saturation] 0 is grey, 1 is the original colour.
List<double> _saturationMatrix(double saturation) {
  const r = .2126, g = .7152, b = .0722;
  final rest = 1 - saturation;
  return [
    r + saturation * (1 - r), g * rest, b * rest, 0, 0, //
    r * rest, g + saturation * (1 - g), b * rest, 0, 0, //
    r * rest, g * rest, b + saturation * (1 - b), 0, 0, //
    0, 0, 0, 1, 0,
  ];
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
                  : 'Tap the pendant to '
                        'start listening.'));
    // No card, no border, no fill: the live line reads as a continuation of
    // the minutes-transcribed line right above it rather than a component.
    return Padding(
      key: const Key('companion_live_transcript'),
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: interim ? _pageInk(context) : _pageInkSoft(context),
          fontSize: 14,
          height: 1.4,
          fontStyle: interim ? FontStyle.normal : FontStyle.italic,
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

class _FirmwareCta extends StatelessWidget {
  const _FirmwareCta({
    required this.release,
    required this.onOpen,
    required this.onDismiss,
  });

  final FirmwareRelease release;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => _BannerCta(
    tileKey: const Key('companion_firmware_notice_tile'),
    dismissKey: const Key('companion_firmware_notice_dismiss'),
    icon: Icons.memory_rounded,
    title: 'Pendant firmware ${release.version}',
    detail: 'A newer firmware is ready to install on your Omi.',
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
    required this.firmwareChecker,
    required this.firmwareDownloader,
    required this.firmwareFlasher,
    required this.openLink,
    required this.rememberedDeviceId,
    required this.connectedDevice,
    required this.capturing,
    required this.segmentCount,
    required this.onForget,
    required this.onDisconnect,
  });

  final AppServices services;
  final bool previewMode;
  final FirmwareUpdateChecker? firmwareChecker;
  final FirmwareDownloader? firmwareDownloader;
  final FirmwareFlasher? firmwareFlasher;
  final LinkOpener openLink;
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

  void _openFirmwareUpdate() {
    unawaited(
      _pushFirmwareUpdate(
        context,
        services: widget.services,
        device: widget.connectedDevice,
        capturing: widget.capturing,
        checker: widget.firmwareChecker ?? FirmwareUpdateChecker(),
        downloader: widget.firmwareDownloader ?? HttpFirmwareDownloader(),
        flasher: widget.firmwareFlasher ?? McuMgrFirmwareFlasher(),
        openLink: widget.openLink,
      ),
    );
  }

  void _openDeveloperOptions() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (routeContext) => _DeveloperOptionsPage(
            device: widget.connectedDevice(),
            capturing: widget.capturing(),
            segmentCount: widget.segmentCount(),
            dfuSupported: widget.services.deviceRelay.dfuSupported,
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
                // Only pendants whose firmware carries the SMP service can be
                // updated over BLE. Everything else — DevKit builds, and any
                // image built without MCUboot OTA — never sees the row, rather
                // than being walked to the end of a flow that cannot finish.
                if (connected && widget.services.deviceRelay.dfuSupported)
                  _PaperTile(
                    key: const Key('companion_firmware_update'),
                    icon: Icons.memory_rounded,
                    title: 'Firmware update',
                    detail: 'Check for a newer pendant firmware.',
                    trailing: const _RowChevron(),
                    onTap: _openFirmwareUpdate,
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
