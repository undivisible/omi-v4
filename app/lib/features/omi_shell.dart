import 'package:flutter/material.dart';

import '../ui/omi_ui.dart';
import 'chat_screen.dart';
import 'currents_screen.dart';
import 'device_screen.dart';
import 'memory_screen.dart';
import 'setup_account_screens.dart';

class OmiShell extends StatefulWidget {
  const OmiShell({super.key});

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
          child: _Screen(index: selected),
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
              selectedIndex: selected,
              onDestinationSelected: (value) =>
                  setState(() => selected = value),
              destinations: [
                for (final destination in destinations.take(5))
                  NavigationDestination(
                    icon: Icon(destination.$1),
                    label: destination.$2,
                  ),
              ],
            ),
    );
  }
}

class _Screen extends StatelessWidget {
  const _Screen({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return switch (index) {
      0 => const ChatScreen(),
      1 => const MemoryScreen(),
      2 => const CurrentsScreen(),
      3 => const DevicesScreen(),
      4 => const SetupScreen(),
      _ => const AccountScreen(),
    };
  }
}
