import 'package:flutter/material.dart';

import '../currents/currents.dart';
import '../ui/omi_ui.dart';

class CurrentsScreen extends StatelessWidget {
  const CurrentsScreen({super.key});

  static final samples = [
    CurrentItem.candidate(
      id: 'launch-momentum',
      evidence: [
        CurrentEvidence(
          sourceId: 'weekly-focus',
          reason: 'Strong focus across 4 sessions this week',
        ),
      ],
      reason: 'Launch momentum',
      timing: CurrentTiming(surfaceAt: DateTime.utc(2026, 7, 21)),
      confidence: .9,
      proposedNextStep: 'Protect a 90-minute block',
      createdAt: DateTime.utc(2026, 7, 21),
    ),
    CurrentItem.candidate(
      id: 'follow-ups',
      evidence: [
        CurrentEvidence(
          sourceId: 'commitments',
          reason: 'Four commitments have no next action',
        ),
      ],
      reason: 'Follow-ups accumulating',
      timing: CurrentTiming(surfaceAt: DateTime.utc(2026, 7, 21)),
      confidence: .8,
      proposedNextStep: 'Draft the messages',
      createdAt: DateTime.utc(2026, 7, 21),
    ),
    CurrentItem.candidate(
      id: 'pricing-decision',
      evidence: [
        CurrentEvidence(
          sourceId: 'pricing-conversations',
          reason: 'Pricing came up in three conversations',
        ),
      ],
      reason: 'Decision resurfacing',
      timing: CurrentTiming(surfaceAt: DateTime.utc(2026, 7, 21)),
      confidence: .75,
      proposedNextStep: 'Show the evidence',
      createdAt: DateTime.utc(2026, 7, 21),
    ),
  ];

  static const accents = [
    Color(0xff73d5c4),
    Color(0xffffb86b),
    Color(0xff77a9ff),
  ];

  @override
  Widget build(BuildContext context) {
    return PageList(
      title: 'Currents',
      subtitle: 'Patterns and opportunities moving through your life.',
      children: [
        for (var index = 0; index < samples.length; index++)
          BaseTile(
            icon: Icons.circle,
            iconColor: accents[index],
            title: samples[index].reason,
            detail:
                '${samples[index].evidence.single.reason}\n${samples[index].proposedNextStep}',
            trailing: const Icon(Icons.arrow_forward_rounded),
          ),
      ],
    );
  }
}
