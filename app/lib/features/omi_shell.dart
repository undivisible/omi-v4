import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../keyboard/keyboard.dart';
import '../menu_bar/desktop_menu_bar.dart';
import 'chat_screen.dart';
import 'cursor_pill.dart';
import 'cursor_pill_controller.dart';
import 'hub_opener.dart';
import 'meeting_assist_panel.dart';
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
  CursorPillController? _cursorPill;

  static const _windowChromeChannel = MethodChannel('omi/window_chrome');

  bool get _isMacDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

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
    _menuBar = DesktopMenuBarController(
      currents: widget.services.currents,
      isListening: () => widget.services.desktopVoice.active,
      onCapture: () => _handleDesktopGesture(ShiftGestureAction.openOverlay),
      onToggleListening: () => _handleDesktopGesture(
        widget.services.desktopVoice.active
            ? ShiftGestureAction.stopVoice
            : ShiftGestureAction.startVoice,
      ),
      onOpenSettings: _openSettings,
    );
    unawaited(_menuBar!.start());
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

  /// Without the Accessibility grant the global keyboard monitor is blind
  /// while another app is frontmost, so the chord and Option+Space silently
  /// stop working system-wide. Surface that once, with the fix.
  void _handleKeyboardNotice(DesktopKeyboardEvent event) {
    if (event is! DesktopGlobalHotkeyUnavailableEvent) return;
    if (_globalHotkeyNoticeShown || !mounted) return;
    _globalHotkeyNoticeShown = true;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'Global shortcuts (double-Shift, $summonOverlayKeybindLabel) only '
          'work inside Omi until Accessibility access is granted in System '
          'Settings → Privacy & Security → Accessibility.',
        ),
        duration: Duration(seconds: 8),
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
  void debugOpenSettingsForTest() => _openSettings();

  /// On macOS settings live in their own native window (a second Flutter
  /// engine hosted by SettingsWindowController); the channel call asks the
  /// Runner to open or front it. Elsewhere — and in tests or previews where
  /// the native side is absent — fall back to the in-window route.
  void _openSettings() {
    if (!mounted) return;
    if (_isMacDesktop && !widget.previewMode) {
      unawaited(() async {
        try {
          await _windowChromeChannel.invokeMethod<void>('openSettings');
        } on MissingPluginException {
          _openSettingsRoute();
        } on PlatformException {
          _openSettingsRoute();
        }
      }());
      return;
    }
    _openSettingsRoute();
  }

  void _openSettingsRoute() {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SettingsScreen(
          services: widget.services,
          previewMode: widget.previewMode,
        ),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _handleDesktopGesture(ShiftGestureAction action) async {
    if (!mounted) return;
    final pill = _cursorPill;
    if (pill != null) {
      await pill.handleGesture(action);
      return;
    }
    await _chatKey.currentState?.handleDesktopGesture(action);
  }

  @override
  void dispose() {
    unawaited(_menuBar?.dispose());
    unawaited(_disposeDesktopGesture());
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
        onShakeSummon: _cursorPill == null
            ? null
            : () => _handleDesktopGesture(ShiftGestureAction.startVoice),
      ),
    );
    final topPadding = widget.previewMode ? 20.0 : 48.0;
    final paddedBody = SafeArea(
      left: !wide,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          wide ? 32 : 18,
          topPadding,
          wide ? 32 : 18,
          12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.previewMode)
              _PreviewNotice(onExit: widget.onExitPreview),
            if (widget.previewMode) const SizedBox(height: 12),
            Expanded(child: chat),
          ],
        ),
      ),
    );
    final pill = _cursorPill;
    final hubBackground = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xff1c1c1a)
        : const Color(0xfff7f6f1);
    final meetingAssist = widget.previewMode
        ? null
        : Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 56, right: 20),
              child: MeetingAssistPanel(services: widget.services),
            ),
          );
    if (pill == null) {
      return Scaffold(
        backgroundColor: hubBackground,
        body: Stack(children: [paddedBody, ?meetingAssist]),
      );
    }
    return ListenableBuilder(
      listenable: pill,
      builder: (context, _) {
        if (pill.state == CursorPillState.listening) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: CursorPill(controller: pill),
          );
        }
        return Scaffold(
          backgroundColor: hubBackground,
          body: Stack(
            children: [
              paddedBody,
              ?meetingAssist,
              Align(
                alignment: Alignment.topLeft,
                child: CursorPill(controller: pill),
              ),
            ],
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
    final dark = Theme.of(context).brightness == Brightness.dark;
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
