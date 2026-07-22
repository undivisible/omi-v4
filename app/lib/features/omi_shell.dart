import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../keyboard/keyboard.dart';
import '../menu_bar/desktop_menu_bar.dart';
import 'chat_screen.dart';
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
  DesktopMenuBarController? _menuBar;

  static const _windowChromeChannel = MethodChannel('omi/window_chrome');
  bool _windowChromeHandlerSet = false;

  bool get _isMacDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    if (widget.previewMode) return;
    if (_isMacDesktop) {
      unawaited(_enterHubChrome());
      _windowChromeChannel.setMethodCallHandler(_handleWindowChromeCall);
      _windowChromeHandlerSet = true;
    }
    _menuBar = DesktopMenuBarController(
      currents: widget.services.currents,
      isListening: () => widget.services.desktopVoice.active,
      onCapture: () => _handleDesktopGesture(ShiftGestureAction.openTextInput),
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

  Future<dynamic> _handleWindowChromeCall(MethodCall call) async {
    if (call.method == 'openSettings') {
      _openSettings();
    }
    return null;
  }

  void _openSettings() {
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
    await _chatKey.currentState?.handleDesktopGesture(action);
  }

  @override
  void dispose() {
    if (_windowChromeHandlerSet) {
      _windowChromeChannel.setMethodCallHandler(null);
    }
    unawaited(_menuBar?.dispose());
    unawaited(_disposeDesktopGesture());
    super.dispose();
  }

  Future<void> _disposeDesktopGesture() async {
    await _desktopGestureActions?.cancel();
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
    return Scaffold(backgroundColor: const Color(0xfff7f6f1), body: paddedBody);
  }
}

class _WarmPaperHub extends StatelessWidget {
  const _WarmPaperHub({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: Color(0xff171716),
        surface: Color(0xfffffefa),
        onSurface: Color(0xff171716),
        onSurfaceVariant: Color(0xff706e68),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xfffffefa),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: Color(0x1a000000)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: Color(0x1a000000)),
        ),
      ),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: ColoredBox(
        key: const Key('warm_paper_hub'),
        color: const Color(0xfff7f6f1),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: child,
        ),
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
