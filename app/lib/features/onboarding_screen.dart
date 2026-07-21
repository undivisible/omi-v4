import 'package:flutter/material.dart';

import '../ui/omi_ui.dart';
import 'omi_shell.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final controller = TextEditingController();
  var step = 0;

  static const prompts = [
    (
      'Let’s build your second brain.',
      'What should I call you, and what are you focused on right now?',
      'I’m Alex. I’m building a product and want help staying focused.',
    ),
    (
      'How should I help?',
      'Tell me what you want me to notice, remember, and act on.',
      'Remember decisions, surface loose ends, and protect my focus.',
    ),
    (
      'Try your assistant.',
      'Ask “what are my tasks?” so I can show you how voice and chat work everywhere.',
      'What are my tasks?',
    ),
  ];

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void next() {
    if (step < prompts.length - 1) {
      setState(() {
        step++;
        controller.clear();
      });
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const OmiShell()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prompt = prompts[step];
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const OmiMark(),
                        const Spacer(),
                        Text('${step + 1} of ${prompts.length}'),
                      ],
                    ),
                    const Spacer(),
                    GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              prompt.$1,
                              style: Theme.of(context).textTheme.displaySmall,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              prompt.$2,
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(color: Colors.white70),
                            ),
                            const SizedBox(height: 28),
                            TextField(
                              key: const Key('onboarding_input'),
                              controller: controller,
                              minLines: 2,
                              maxLines: 4,
                              decoration: InputDecoration(
                                hintText: prompt.$3,
                                suffixIcon: IconButton(
                                  key: const Key('continue_onboarding'),
                                  onPressed: next,
                                  icon: const Icon(Icons.arrow_upward_rounded),
                                ),
                              ),
                              onSubmitted: (_) => next(),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'Your answers become editable memory, not a permanent profile.',
                      textAlign: TextAlign.center,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
