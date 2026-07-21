import 'package:flutter/material.dart';

import '../ui/omi_ui.dart';

class CurrentsScreen extends StatelessWidget {
  const CurrentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PageList(
      title: 'Currents',
      subtitle: 'Patterns and opportunities moving through your life.',
      children: [
        BaseTile(
          icon: Icons.waves_rounded,
          title: 'No Currents yet',
          detail:
              'Currents will appear after Omi has connected evidence and a recommendation model.',
          trailing: Icon(Icons.hourglass_empty_rounded),
        ),
      ],
    );
  }
}
