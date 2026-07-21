import 'package:flutter/material.dart';

import '../app_services.dart';
import '../ui/omi_ui.dart';
import 'chat_screen.dart';
import 'currents_screen.dart';
import 'device_screen.dart';
import 'memory_screen.dart';
import 'setup_account_screens.dart';

class OmiShell extends StatefulWidget {
  const OmiShell({required this.services, this.previewMode = false, super.key});

  final AppServices services;
  final bool previewMode;

  @override
  State<OmiShell> createState() => _OmiShellState();
}

class _OmiShellState extends State<OmiShell> {
  var selected = 0;

  static const destinations = [
    (Icons.chat_bubble_outline_rounded, 'Chat'),
    (Icons.auto_stories_outlined, 'Memory'),
    (Icons.waves_rounded, 'Currents'),
    (Icons.devices_other_rounded, 'Devices'),
    (Icons.checklist_rounded, 'Setup'),
    (Icons.person_outline_rounded, 'Account'),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final body = GradientBackground(
      child: SafeArea(
        left: !wide,
        child: Padding(
          padding: EdgeInsets.fromLTRB(wide ? 32 : 18, 20, wide ? 32 : 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.previewMode) const _PreviewNotice(),
              if (widget.previewMode) const SizedBox(height: 12),
              Expanded(
                child: _Screen(
                  index: selected,
                  services: widget.services,
                  previewMode: widget.previewMode,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Scaffold(
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  backgroundColor: const Color(0xff0b1013),
                  selectedIndex: selected,
                  onDestinationSelected: (value) =>
                      setState(() => selected = value),
                  extended: MediaQuery.sizeOf(context).width >= 1050,
                  leading: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: OmiMark(),
                  ),
                  destinations: [
                    for (final destination in destinations)
                      NavigationRailDestination(
                        icon: Icon(destination.$1),
                        label: Text(destination.$2),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1, color: Color(0x22ffffff)),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
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

class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Interface preview. Services are not connected.',
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x22ffc66d),
        border: Border.all(color: const Color(0x66ffc66d)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.visibility_outlined, size: 18, color: Color(0xffffc66d)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'INTERFACE PREVIEW · Account, memory, AI, permissions, and actions are not connected.',
                style: TextStyle(fontSize: 12, color: Color(0xffffd99a)),
              ),
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
  });

  final int index;
  final AppServices services;
  final bool previewMode;

  @override
  Widget build(BuildContext context) {
    return switch (index) {
      0 => const ChatScreen(),
      1 => MemoryScreen(services: services, previewMode: previewMode),
      2 => const CurrentsScreen(),
      3 => DevicesScreen(previewMode: previewMode),
      4 => SetupScreen(services: services, previewMode: previewMode),
      _ => AccountScreen(services: services, previewMode: previewMode),
    };
  }
}
