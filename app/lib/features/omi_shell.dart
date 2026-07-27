import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../capabilities/desktop_capabilities.dart';
import '../capabilities/hub_platform.dart';
import '../demo/demo_mode.dart';
import '../keyboard/keyboard.dart';
import '../menu_bar/desktop_menu_bar.dart';
import '../native/native_hub.dart';
import 'chat_screen.dart';
import 'cursor_pill.dart';
import 'cursor_pill_controller.dart';
import 'hub_opener.dart';
import 'meeting_assist_panel.dart';
import 'pill_panel.dart';
import 'setup_account_screens.dart';

class OmiShell extends StatefulWidget {
  const OmiShell({
    required this.services,
    this.previewMode = false,
    this.onExitPreview,
    this.desktopKeyboard,
    this.desktopGesture,
    super.key,
  });

  final AppServices services;
  final bool previewMode;
  final VoidCallback? onExitPreview;
  final DesktopKeyboard? desktopKeyboard;
  final DesktopGestureController? desktopGesture;

  @override
  State<OmiShell> createState() => _OmiShellState();
}

class _OmiShellState extends State<OmiShell> {
  final _chatKey = GlobalKey<ChatScreenState>();
  late final _desktopKeyboard = widget.desktopKeyboard ?? DesktopKeyboard();
  DesktopGestureController? _desktopGesture;
  StreamSubscription<ShiftGestureAction>? _desktopGestureActions;
  StreamSubscription<DesktopKeyboardEvent>? _keyboardNotices;
  bool _globalHotkeyNoticeShown = false;
  DesktopMenuBarController? _menuBar;
  StreamSubscription<NativeEvent>? _meetingStateEvents;
  CursorPillController? _cursorPill;
  PillPanelHost? _pillPanelHost;
  bool _appActive = false;
  DesktopInputDiagnosticsEvent? _inputDiagnostics;
  bool _settingsRouteOpen = false;

  static const _windowChromeChannel = MethodChannel('omi/window_chrome');

  bool get _isMacDesktop => desktopChromeSupported;

  @override
  void initState() {
    super.initState();
    if (widget.previewMode) return;
    if (_isMacDesktop) {
      unawaited(_enterHubChrome());
    }
    _cursorPill = CursorPillController.forServices(
      widget.services,
      openHub: () {
        unawaited(openHubWindow());
        _chatKey.currentState?.showAllTasks();
      },
    );
    if (_isMacDesktop) {
      // The pill lives in its own panel window backed by a second engine;
      // this half of the bridge keeps that engine in sync and executes what
      // it relays back.
      _pillPanelHost = PillPanelHost(
        controller: _cursorPill!,
        draft: widget.services.generateDraft,
      )..start();
    }
    _menuBar = DesktopMenuBarController(
      currents: widget.services.currents,
      isListening: () => widget.services.desktopVoice.active,
      isMeetingActive: () => widget.services.meetingActive,
      // Menu Capture is always overlay-first — even when the hub window is
      // already frontmost. The keyboard chord still prefers the hub composer
      // in that case (see `_handleDesktopGesture`); the menu item must not.
      onCapture: _summonOverlayCapture,
      onToggleListening: () => _handleDesktopGesture(
        widget.services.desktopVoice.active
            ? ShiftGestureAction.stopVoice
            : ShiftGestureAction.startVoice,
      ),
      onToggleMeeting: _toggleMeeting,
      onOpenSettings: _openSettings,
    );
    unawaited(_menuBar!.start());
    _meetingStateEvents = widget.services.nativeEvents.listen((event) {
      if (event is! NativeEventMeetingStateChanged) return;
      unawaited(_menuBar?.refresh());
    });
    final gesture =
        widget.desktopGesture ??
        (_desktopKeyboard.supported
            ? DesktopGestureController(keyboard: _desktopKeyboard)
            : null);
    if (gesture == null) return;
    _desktopGesture = gesture..start();
    _desktopGestureActions = gesture.actions.listen(_handleDesktopGesture);
    _keyboardNotices = _desktopKeyboard.events.listen(_handleKeyboardNotice);
  }

  /// Without Input Monitoring the global keyboard tap cannot install while
  /// another app is frontmost, so double-Shift silently stops working
  /// system-wide. Surface that once and open the system prompt.
  void _handleKeyboardNotice(DesktopKeyboardEvent event) {
    if (event is DesktopAppActivationEvent) {
      _appActive = event.active;
      return;
    }
    if (event is DesktopInputDiagnosticsEvent) {
      if (!mounted) return;
      final previous = _inputDiagnostics;
      if (previous?.trusted == event.trusted &&
          previous?.inputMonitoring == event.inputMonitoring &&
          previous?.tapInstalled == event.tapInstalled) {
        return;
      }
      setState(() => _inputDiagnostics = event);
      return;
    }
    if (event is! DesktopGlobalHotkeyUnavailableEvent) return;
    if (!event.inputMonitoring) {
      unawaited(
        widget.services.capabilities.request(CoreCapability.inputMonitoring),
      );
    }
    if (_globalHotkeyNoticeShown || !mounted) return;
    _globalHotkeyNoticeShown = true;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          event.inputMonitoring
              ? 'Global double-Shift needs Input Monitoring in System Settings '
                    '→ Privacy & Security. It still works inside the hub window.'
              : 'Allow Input Monitoring so double-Shift works outside Omi. '
                    'System Settings should open now.',
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  Future<void> _enterHubChrome() async {
    try {
      await _windowChromeChannel.invokeMethod('enterHub');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @visibleForTesting
  void debugOpenSettingsForTest({SettingsSection? section}) =>
      _openSettings(section: section);

  /// On macOS settings live in their own native window (a second Flutter
  /// engine hosted by SettingsWindowController); the channel call asks the
  /// Runner to open or front it. Elsewhere — and in tests or previews where
  /// the native side is absent — fall back to the in-window route.
  ///
  /// [section] is the anchor the caller wants: it rides the channel as the
  /// section's plain name so the settings engine can land there instead of at
  /// the top, and the in-window fallback honours the same request.
  void _openSettings({SettingsSection? section}) {
    if (!mounted) return;
    if (_isMacDesktop && !widget.previewMode) {
      unawaited(() async {
        try {
          await _windowChromeChannel.invokeMethod<void>(
            'openSettings',
            section?.name,
          );
        } on MissingPluginException catch (error, stack) {
          _reportSettingsFallback(error, stack);
          _openSettingsRoute(section);
        } on PlatformException catch (error, stack) {
          _reportSettingsFallback(error, stack);
          _openSettingsRoute(section);
        }
      }());
      return;
    }
    _openSettingsRoute(section);
  }

  /// On macOS the native settings window is the only correct surface, so
  /// reaching the in-window route there means the Runner never answered —
  /// a regression, not a fallback. Say so out loud in debug builds; release
  /// still degrades to the route rather than showing nothing.
  void _reportSettingsFallback(Object error, StackTrace stack) {
    assert(() {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'omi',
          context: ErrorDescription(
            'asking the Runner to open the native settings window over '
            'omi/window_chrome. The in-window route is a fallback for '
            'platforms without it and must never be reached on macOS.',
          ),
        ),
      );
      return true;
    }());
  }

  void _openSettingsRoute([SettingsSection? section]) {
    if (!mounted || _settingsRouteOpen) return;
    _settingsRouteOpen = true;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (context) => SettingsScreen(
              services: widget.services,
              previewMode: widget.previewMode,
              initialSection: section,
            ),
            fullscreenDialog: true,
          ),
        )
        .whenComplete(() => _settingsRouteOpen = false);
  }

  Future<void> _toggleMeeting() async {
    try {
      if (widget.services.meetingActive) {
        widget.services.stopMeeting();
      } else {
        widget.services.startMeeting();
      }
    } on StateError {
      return;
    }
  }

  Future<void> _summonOverlayCapture() async {
    if (!mounted) return;
    final pill = _cursorPill;
    if (pill != null) {
      await pill.handleGesture(ShiftGestureAction.openOverlay);
      return;
    }
    await _chatKey.currentState?.handleDesktopGesture(
      ShiftGestureAction.openOverlay,
    );
  }

  Future<void> _handleDesktopGesture(ShiftGestureAction action) async {
    if (!mounted) return;
    final pill = _cursorPill;
    // With the hub already frontmost the chord means "let me type here": the
    // floating panel would only cover the window it was summoned from, so the
    // caret goes to the hub's own composer instead. Any surface already up
    // keeps its own toggle semantics. Menu Capture bypasses this via
    // `_summonOverlayCapture`.
    if (action == ShiftGestureAction.openOverlay &&
        _appActive &&
        (pill == null || pill.state == CursorPillState.hidden)) {
      _chatKey.currentState?.focusInput();
      return;
    }
    if (pill != null) {
      await pill.handleGesture(action);
      return;
    }
    await _chatKey.currentState?.handleDesktopGesture(action);
  }

  @override
  void dispose() {
    unawaited(_meetingStateEvents?.cancel());
    unawaited(_menuBar?.dispose());
    unawaited(_disposeDesktopGesture());
    _pillPanelHost?.dispose();
    _cursorPill?.dispose();
    super.dispose();
  }

  Future<void> _disposeDesktopGesture() async {
    await _desktopGestureActions?.cancel();
    await _keyboardNotices?.cancel();
    await _desktopGesture?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final chat = _WarmPaperHub(
      child: ChatScreen(
        key: _chatKey,
        services: widget.services,
        previewMode: widget.previewMode,
        desktopKeyboard: _desktopKeyboard,
        onDesktopGestureReset: _desktopGesture?.reset,
        onOpenProviderSettings: () =>
            _openSettings(section: SettingsSection.providers),
      ),
    );
    final topPadding = widget.previewMode
        ? 20.0
        : omiDemoMode
        ? 10.0
        : 48.0;
    final sidePadding = wide
        ? (omiDemoMode ? 20.0 : 32.0)
        : (omiDemoMode ? 12.0 : 18.0);
    final paddedBody = SafeArea(
      left: !wide,
      child: Padding(
        padding: EdgeInsets.fromLTRB(sidePadding, topPadding, sidePadding, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.previewMode)
              _PreviewNotice(onExit: widget.onExitPreview),
            if (widget.previewMode) const SizedBox(height: 12),
            if (_desktopKeyboard.supported)
              if (_inputDiagnostics case final diagnostics?
                  when !diagnostics.globalCaptureLive) ...[
                _GlobalInputNotice(
                  diagnostics: diagnostics,
                  onGrant: () => unawaited(
                    !diagnostics.inputMonitoring
                        ? widget.services.capabilities.request(
                            CoreCapability.inputMonitoring,
                          )
                        : widget.services.capabilities.request(
                            CoreCapability.accessibility,
                          ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            Expanded(child: chat),
          ],
        ),
      ),
    );
    // On macOS the pill renders inside its own panel window (a second Flutter
    // engine); drawing it in the hub too would show it twice.
    final pill = _isMacDesktop && !widget.previewMode ? null : _cursorPill;
    final hubBackground = omiDemoMode
        ? Colors.transparent
        : Theme.of(context).brightness == Brightness.dark
        ? const Color(0xff1c1c1a)
        : const Color(0xfff7f6f1);
    final meetingAssist = widget.previewMode || !meetingAssistSupported
        ? null
        : Align(
            alignment: Alignment.topCenter,
            child: MeetingAssistPanel(services: widget.services),
          );
    if (pill == null) {
      return _DemoHubBackdrop(
        child: Scaffold(
          backgroundColor: hubBackground,
          body: Stack(children: [paddedBody, ?meetingAssist]),
        ),
      );
    }
    return ListenableBuilder(
      listenable: pill,
      builder: (context, _) {
        // Listening renders nothing here: the edge glow and follow-cursor
        // waveform are native windows, and the hub must stay exactly as it
        // is while voice is up.
        final showPill = pill.state != CursorPillState.listening;
        return _DemoHubBackdrop(
          child: Scaffold(
            backgroundColor: hubBackground,
            body: Stack(
              children: [
                paddedBody,
                ?meetingAssist,
                if (showPill)
                  Align(
                    alignment: Alignment.topLeft,
                    child: CursorPill(controller: pill),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WarmPaperHub extends StatelessWidget {
  const _WarmPaperHub({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark =
        !omiDemoMode && Theme.of(context).brightness == Brightness.dark;
    return Theme(
      data: Theme.of(context).copyWith(
        brightness: dark ? Brightness.dark : Brightness.light,
        colorScheme: dark
            ? const ColorScheme.dark(
                primary: Color(0xfffffcec),
                surface: Color(0xff232321),
                onSurface: Color(0xfff4f2ea),
                onSurfaceVariant: Color(0xffa6a49c),
              )
            : const ColorScheme.light(
                primary: Color(0xff171716),
                surface: Color(0xfffffefa),
                onSurface: Color(0xff171716),
                onSurfaceVariant: Color(0xff706e68),
              ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: dark ? const Color(0xff232321) : const Color(0xfffffefa),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(
              color: dark ? const Color(0x1affffff) : const Color(0x1a000000),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(
              color: dark ? const Color(0x1affffff) : const Color(0x1a000000),
            ),
          ),
        ),
      ),
      child: Padding(
        key: const Key('warm_paper_hub'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: child,
      ),
    );
  }
}

class _DemoHubBackdrop extends StatelessWidget {
  const _DemoHubBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!omiDemoMode) return child;
    return DecoratedBox(
      key: const Key('demo_hub_backdrop'),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xffeadbc7), Color(0xffe0d1bd), Color(0xffd5e0d3)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(-1, -1),
                  radius: 1.1,
                  colors: [Color(0x889b5948), Color(0x009b5948)],
                ),
              ),
            ),
          ),
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(1.1, 1),
                  radius: 1.05,
                  colors: [Color(0x665b8291), Color(0x00876375)],
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// The visible truth about global input capture. Without Input Monitoring the
/// double-Shift chord only works while Omi is frontmost, which otherwise looks
/// like the feature is simply broken.
class _GlobalInputNotice extends StatelessWidget {
  const _GlobalInputNotice({required this.diagnostics, required this.onGrant});

  final DesktopInputDiagnosticsEvent diagnostics;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const Key('global_input_notice'),
    decoration: BoxDecoration(
      color: const Color(0x22ffc66d),
      border: Border.all(color: const Color(0x66ffc66d)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Icon(
            Icons.keyboard_alt_outlined,
            size: 18,
            color: Color(0xffffc66d),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Global double-Shift only works outside Omi once Input Monitoring '
              'is granted. '
              'Accessibility: '
              '${diagnostics.trusted ? "granted" : "not granted"} · '
              'Input Monitoring: '
              '${diagnostics.inputMonitoring ? "granted" : "not granted"} · '
              'input tap: ${diagnostics.tapInstalled ? "live" : "not running"}.',
              style: const TextStyle(fontSize: 12, color: Color(0xffffd99a)),
            ),
          ),
          TextButton(
            key: const Key('global_input_notice_grant'),
            onPressed: onGrant,
            child: Text(
              diagnostics.inputMonitoring
                  ? 'Open Accessibility'
                  : 'Allow Input Monitoring',
            ),
          ),
        ],
      ),
    ),
  );
}

class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice({this.onExit});

  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Interface preview. Services are not connected.',
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x22ffc66d),
        border: Border.all(color: const Color(0x66ffc66d)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.visibility_outlined,
              size: 18,
              color: Color(0xffffc66d),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'INTERFACE PREVIEW · Account, memory, AI, permissions, and actions are not connected.',
                style: TextStyle(fontSize: 12, color: Color(0xffffd99a)),
              ),
            ),
            if (onExit != null)
              TextButton(
                key: const Key('exit_interface_preview'),
                onPressed: onExit,
                child: const Text('Back to setup'),
              ),
          ],
        ),
      ),
    ),
  );
}
