import 'package:flutter/material.dart';

import '../ui/omi_ui.dart';

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageTitle(
          title: 'Good morning',
          subtitle: 'Your day, remembered and ready.',
        ),
        const SizedBox(height: 20),
        Expanded(
          child: ListView(
            children: [
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const OmiLabel('NEXT BEST STEP'),
                      const SizedBox(height: 10),
                      Text(
                        'Finish the launch brief',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'You left two pricing decisions open yesterday. I can pull them together.',
                      ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: () {},
                        icon: const Icon(Icons.auto_awesome_rounded),
                        label: const Text('Work through it with me'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const _MessageBubble(
                text:
                    'I found three tasks from yesterday and one meeting that needs a follow-up. Want the short version?',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const TextField(
          key: Key('chat_input'),
          decoration: InputDecoration(
            hintText: 'Ask anything or tell Omi what to do',
            prefixIcon: Icon(Icons.add_circle_outline_rounded),
            suffixIcon: Icon(Icons.mic_none_rounded),
          ),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: GlassCard(
          child: Padding(padding: const EdgeInsets.all(18), child: Text(text)),
        ),
      ),
    );
  }
}
