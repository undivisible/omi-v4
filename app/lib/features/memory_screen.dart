import 'package:flutter/material.dart';

import '../ui/omi_ui.dart';

class MemoryScreen extends StatelessWidget {
  const MemoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PageList(
      title: 'Memory',
      subtitle: 'What Omi knows, with sources you can inspect.',
      children: [
        StatRow(
          values: [('1,284', 'moments'), ('218', 'facts'), ('32', 'people')],
        ),
        _MemoryTile(
          icon: Icons.work_outline_rounded,
          title: 'You are preparing a product launch',
          detail: 'Updated today · 7 sources',
        ),
        _MemoryTile(
          icon: Icons.person_outline_rounded,
          title: 'Sam owns the mobile release',
          detail: 'Updated yesterday · 3 sources',
        ),
        _MemoryTile(
          icon: Icons.tune_rounded,
          title: 'You prefer decisions in short numbered lists',
          detail: 'Learned preference · editable',
        ),
      ],
    );
  }
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => BaseTile(
    icon: icon,
    title: title,
    detail: detail,
    trailing: const Icon(Icons.chevron_right_rounded),
  );
}
