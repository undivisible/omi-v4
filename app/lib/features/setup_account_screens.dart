import 'package:flutter/material.dart';

import '../channels/channels.dart';
import '../ui/omi_ui.dart';

class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  static const channels = [ChannelProvider.telegram, ChannelProvider.blooio];

  @override
  Widget build(BuildContext context) {
    return PageList(
      title: 'Finish setup',
      subtitle: 'Each connection makes your assistant more useful.',
      children: [
        const _SetupTile(
          icon: Icons.mic_none_rounded,
          title: 'Try voice',
          detail: 'Ask “what are my tasks?”',
          done: true,
        ),
        const _SetupTile(
          icon: Icons.lock_outline_rounded,
          title: 'Allow screen understanding',
          detail: 'Keep visual memory under your control',
        ),
        _SetupTile(
          icon: Icons.send_outlined,
          title: 'Connect ${_channelName(channels[0])}',
          detail: 'Use the same assistant from any device',
        ),
        _SetupTile(
          icon: Icons.chat_bubble_outline_rounded,
          title: 'Connect ${_channelName(channels[1])}',
          detail: 'Reach Omi through iMessage and SMS',
        ),
        const _SetupTile(
          icon: Icons.description_outlined,
          title: 'Connect Notion',
          detail: 'Bring your workspace into memory',
        ),
      ],
    );
  }

  static String _channelName(ChannelProvider provider) => switch (provider) {
    ChannelProvider.telegram => 'Telegram',
    ChannelProvider.blooio => 'Blooio',
  };
}

class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PageList(
      title: 'Account',
      subtitle: 'Identity, plan, providers, and agent control.',
      children: [
        _AccountTile(
          icon: Icons.person_outline_rounded,
          title: 'Profile',
          detail: 'Name, goals, and learned preferences',
        ),
        _AccountTile(
          icon: Icons.shield_outlined,
          title: 'Agent control',
          detail: 'Approve once · Ask when blocked',
        ),
        _AccountTile(
          icon: Icons.key_outlined,
          title: 'AI providers',
          detail: 'Connect ChatGPT, xAI, or your own key',
        ),
        _AccountTile(
          icon: Icons.credit_card_outlined,
          title: 'Plan',
          detail: 'Omi Free · AI is bring-your-own',
        ),
      ],
    );
  }
}

class _SetupTile extends StatelessWidget {
  const _SetupTile({
    required this.icon,
    required this.title,
    required this.detail,
    this.done = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool done;

  @override
  Widget build(BuildContext context) => BaseTile(
    icon: icon,
    title: title,
    detail: detail,
    trailing: Icon(
      done ? Icons.check_circle_rounded : Icons.arrow_forward_rounded,
      color: done ? const Color(0xff73d5c4) : null,
    ),
  );
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
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
