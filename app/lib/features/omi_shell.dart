import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../keyboard/keyboard.dart';
import '../menu_bar/desktop_menu_bar.dart';
import '../ui/omi_ui.dart';
import 'chat_screen.dart';
import 'currents_screen.dart';
import 'device_screen.dart';
import 'memory_screen.dart';
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
  var selected = 0;
  var _showOpeningGradient = true;
  final _chatKey = GlobalKey<ChatScreenState>();
  late final _desktopKeyboard = widget.desktopKeyboard ?? DesktopKeyboard();
  DesktopGestureController? _desktopGesture;
  StreamSubscription<ShiftGestureAction>? _desktopGestureActions;
  DesktopMenuBarController? _menuBar;
  Timer? _openingGradientTimer;

  static const destinations = [
    (Icons.chat_bubble_outline_rounded, 'Chat'),
    (Icons.auto_stories_outlined, 'Memory'),
    (Icons.waves_rounded, 'Currents'),
    (Icons.devices_other_rounded, 'Devices'),
    (Icons.checklist_rounded, 'Setup'),
    (Icons.person_outline_rounded, 'Account'),
  ];

  @override
  void initState() {
    super.initState();
    _openingGradientTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _showOpeningGradient = false);
    });
    if (widget.previewMode) return;
    _menuBar = DesktopMenuBarController(
      currents: widget.services.currents,
      isListening: () => widget.services.desktopVoice.active,
      onCapture: () => _handleDesktopGesture(ShiftGestureAction.openTextInput),
      onToggleListening: () => _handleDesktopGesture(
        widget.services.desktopVoice.active
            ? ShiftGestureAction.stopVoice
            : ShiftGestureAction.startVoice,
      ),
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

  Future<void> _handleDesktopGesture(ShiftGestureAction action) async {
    if (!mounted) return;
    if (selected != 0) {
      setState(() => selected = 0);
      await WidgetsBinding.instance.endOfFrame;
    }
    await _chatKey.currentState?.handleDesktopGesture(action);
  }

  @override
  void dispose() {
    _openingGradientTimer?.cancel();
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
      showOpeningGradient: _showOpeningGradient,
      child: ChatScreen(
        key: _chatKey,
        services: widget.services,
        previewMode: widget.previewMode,
        desktopKeyboard: _desktopKeyboard,
        onDesktopGestureReset: _desktopGesture?.reset,
      ),
    );
    final body = Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: selected != 0,
          child: TickerMode(enabled: selected == 0, child: chat),
        ),
        if (selected != 0)
          GradientBackground(
            child: _Screen(
              index: selected,
              services: widget.services,
              previewMode: widget.previewMode,
              chatKey: _chatKey,
              desktopKeyboard: _desktopKeyboard,
              onDesktopGestureReset: _desktopGesture?.reset,
              onOpenChat: () => setState(() => selected = 0),
            ),
          ),
      ],
    );
    final paddedBody = SafeArea(
      left: !wide,
      child: Padding(
        padding: EdgeInsets.fromLTRB(wide ? 32 : 18, 20, wide ? 32 : 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.previewMode)
              _PreviewNotice(onExit: widget.onExitPreview),
            if (widget.previewMode) const SizedBox(height: 12),
            Expanded(child: body),
          ],
        ),
      ),
    );
    return Scaffold(
      backgroundColor: selected == 0
          ? const Color(0xfff7f6f1)
          : const Color(0xff0b1013),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  backgroundColor: selected == 0
                      ? const Color(0xffefeee9)
                      : const Color(0xff0b1013),
                  selectedIndex: selected,
                  onDestinationSelected: (value) =>
                      setState(() => selected = value),
                  extended: MediaQuery.sizeOf(context).width >= 1050,
                  selectedIconTheme: IconThemeData(
                    color: selected == 0
                        ? const Color(0xff171716)
                        : const Color(0xff73d5c4),
                  ),
                  unselectedIconTheme: IconThemeData(
                    color: selected == 0
                        ? const Color(0xff8d8980)
                        : Colors.white54,
                  ),
                  selectedLabelTextStyle: TextStyle(
                    color: selected == 0
                        ? const Color(0xff171716)
                        : Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelTextStyle: TextStyle(
                    color: selected == 0
                        ? const Color(0xff706e68)
                        : Colors.white60,
                  ),
                  leading: Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: selected == 0
                        ? const _WarmOmiMark()
                        : const OmiMark(),
                  ),
                  destinations: [
                    for (final destination in destinations)
                      NavigationRailDestination(
                        icon: Icon(destination.$1),
                        label: Text(destination.$2),
                      ),
                  ],
                ),
                VerticalDivider(
                  width: 1,
                  color: selected == 0
                      ? const Color(0x14000000)
                      : const Color(0x22ffffff),
                ),
                Expanded(child: paddedBody),
              ],
            )
          : paddedBody,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              backgroundColor: selected == 0 ? const Color(0xfff7f6f1) : null,
              indicatorColor: selected == 0 ? const Color(0x14171716) : null,
              selectedIndex: selected < 3 ? selected : 3,
              onDestinationSelected: (value) {
                if (value < 3) {
                  setState(() => selected = value);
                } else {
                  _showMore();
                }
              },
              destinations: const [
                NavigationDestination(
                  key: ValueKey('narrow_destination_0'),
                  icon: Icon(Icons.chat_bubble_outline_rounded),
                  label: 'Chat',
                ),
                NavigationDestination(
                  key: ValueKey('narrow_destination_1'),
                  icon: Icon(Icons.auto_stories_outlined),
                  label: 'Memory',
                ),
                NavigationDestination(
                  key: ValueKey('narrow_destination_2'),
                  icon: Icon(Icons.waves_rounded),
                  label: 'Currents',
                ),
                NavigationDestination(
                  key: ValueKey('narrow_more'),
                  icon: Icon(Icons.more_horiz_rounded),
                  label: 'More',
                ),
              ],
            ),
    );
  }

  Future<void> _showMore() async {
    final next = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final index in const [3, 4, 5])
              ListTile(
                key: ValueKey('narrow_destination_$index'),
                leading: Icon(destinations[index].$1),
                title: Text(destinations[index].$2),
                selected: selected == index,
                onTap: () => Navigator.pop(context, index),
              ),
          ],
        ),
      ),
    );
    if (next != null && mounted) setState(() => selected = next);
  }
}

class _WarmOmiMark extends StatelessWidget {
  const _WarmOmiMark();

  @override
  Widget build(BuildContext context) => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.blur_on_rounded, color: Color(0xff171716), size: 28),
      SizedBox(width: 10),
      Text(
        'omi',
        style: TextStyle(
          color: Color(0xff171716),
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}

class _WarmPaperHub extends StatelessWidget {
  const _WarmPaperHub({required this.showOpeningGradient, required this.child});

  final bool showOpeningGradient;
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
      child: Stack(
        key: const Key('warm_paper_hub'),
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xfff7f6f1)),
          const IgnorePointer(child: _EdgeGradient()),
          AnimatedOpacity(
            key: const Key('hub_opening_gradient'),
            opacity: showOpeningGradient ? 1 : 0,
            duration: const Duration(milliseconds: 700),
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 1.05,
                    colors: [Color(0xfffffcec), Color(0x00fffcec)],
                    stops: [0, 1],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: child,
          ),
        ],
      ),
    ),
  );
}

class _EdgeGradient extends StatelessWidget {
  const _EdgeGradient();

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: const [
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-1.15, -1.1),
            radius: .9,
            colors: [Color(0x55f25e6b), Color(0x00f25e6b)],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(1.15, -.9),
            radius: .9,
            colors: [Color(0x5596c4ff), Color(0x0096c4ff)],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(.9, 1.15),
            radius: .9,
            colors: [Color(0x55d3e081), Color(0x00d3e081)],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-1.1, 1.05),
            radius: .9,
            colors: [Color(0x55f2c2ac), Color(0x00f2c2ac)],
          ),
        ),
      ),
    ],
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

class _Screen extends StatelessWidget {
  const _Screen({
    required this.index,
    required this.services,
    required this.previewMode,
    required this.chatKey,
    required this.desktopKeyboard,
    required this.onDesktopGestureReset,
    required this.onOpenChat,
  });

  final int index;
  final AppServices services;
  final bool previewMode;
  final GlobalKey<ChatScreenState> chatKey;
  final DesktopKeyboard desktopKeyboard;
  final VoidCallback? onDesktopGestureReset;
  final VoidCallback onOpenChat;

  @override
  Widget build(BuildContext context) {
    return switch (index) {
      0 => ChatScreen(
        key: chatKey,
        services: services,
        previewMode: previewMode,
        desktopKeyboard: desktopKeyboard,
        onDesktopGestureReset: onDesktopGestureReset,
      ),
      1 => MemoryScreen(services: services, previewMode: previewMode),
      2 => CurrentsScreen(
        controller: previewMode ? null : services.currents,
        onActionHandoff: services.currents == null
            ? null
            : (handoff) async {
                await services.handoffCurrentAction(handoff);
                onOpenChat();
              },
      ),
      3 => DevicesScreen(services: services, previewMode: previewMode),
      4 => SetupScreen(services: services, previewMode: previewMode),
      _ => AccountScreen(services: services, previewMode: previewMode),
    };
  }
}
