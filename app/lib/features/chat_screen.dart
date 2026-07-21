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
          title: 'Chat',
          subtitle: 'Your thinking partner across every connected device.',
        ),
        const SizedBox(height: 20),
        Expanded(
          child: SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: const GlassCard(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.forum_outlined, size: 36),
                        SizedBox(height: 14),
                        Text(
                          'Chat is not connected yet',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Finish account and model setup before sending your first message.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white60),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const TextField(
          key: Key('chat_input'),
          enabled: false,
          decoration: InputDecoration(
            hintText: 'Connect an account and model to start chatting',
            prefixIcon: Icon(Icons.add_circle_outline_rounded),
            suffixIcon: Icon(Icons.mic_none_rounded),
          ),
        ),
      ],
    );
  }
}
