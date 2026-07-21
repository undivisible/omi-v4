import 'package:flutter/material.dart';

import '../app_services.dart';
import '../onboarding/onboarding_controller.dart';
import '../ui/omi_ui.dart';
import 'omi_shell.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({required this.services, super.key});

  final AppServices services;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final answerController = TextEditingController();
  final onboarding = OnboardingController();

  static const prompts = [
    (
      'Introduce yourself.',
      'What should Omi call you, and what are you focused on right now?',
      'I’m Alex. I’m building a product and want help staying focused.',
    ),
    (
      'Shape your thinking partner.',
      'What would you want Omi to notice, remember, or help with?',
      'Remember decisions, surface loose ends, and protect my focus.',
    ),
    (
      'Preview the voice lesson.',
      'Type the phrase the connected assistant will use during voice onboarding.',
      'What are my tasks?',
    ),
  ];

  @override
  void initState() {
    super.initState();
    onboarding.addListener(_refresh);
  }

  @override
  void dispose() {
    onboarding.removeListener(_refresh);
    onboarding.dispose();
    answerController.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _submitAnswer() {
    if (onboarding.submitAnswer(
      answerController.text,
      questionCount: prompts.length,
    )) {
      answerController.clear();
    }
  }

  void _openPreview() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => OmiShell(services: widget.services, previewMode: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: [OmiMark(), _PreviewBadge()],
                    ),
                    const SizedBox(height: 48),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: switch (onboarding.stage) {
                        OnboardingStage.introduction => _Introduction(
                          key: const ValueKey('introduction'),
                          acknowledged: onboarding.previewAcknowledged,
                          validationMessage: onboarding.validationMessage,
                          configurationMessage:
                              widget.services.configurationMessage,
                          onAcknowledged: onboarding.setPreviewAcknowledged,
                          onContinue: onboarding.continueFromIntroduction,
                        ),
                        OnboardingStage.profile => _ProfileQuestion(
                          key: ValueKey(onboarding.questionIndex),
                          prompt: prompts[onboarding.questionIndex],
                          index: onboarding.questionIndex,
                          count: prompts.length,
                          controller: answerController,
                          validationMessage: onboarding.validationMessage,
                          onContinue: _submitAnswer,
                        ),
                        OnboardingStage.permissions => _ProductionGate(
                          key: const ValueKey('permissions'),
                          configurationMessage:
                              widget.services.configurationMessage,
                          onOpenPreview: _openPreview,
                        ),
                      },
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Preview answers exist only in memory until this screen closes. Nothing is saved to an account or memory store.',
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

class _PreviewBadge extends StatelessWidget {
  const _PreviewBadge();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0x1fffffff),
      border: Border.all(color: const Color(0x33ffffff)),
      borderRadius: BorderRadius.circular(999),
    ),
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Text('INTERFACE PREVIEW', style: TextStyle(fontSize: 11)),
    ),
  );
}

class _Introduction extends StatelessWidget {
  const _Introduction({
    required this.acknowledged,
    required this.validationMessage,
    required this.configurationMessage,
    required this.onAcknowledged,
    required this.onContinue,
    super.key,
  });

  final bool acknowledged;
  final String? validationMessage;
  final String configurationMessage;
  final ValueChanged<bool> onAcknowledged;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => GlassCard(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Let’s build your second brain.',
            style: Theme.of(context).textTheme.displaySmall,
          ),
          const SizedBox(height: 12),
          Text(
            'This build demonstrates the onboarding and product interface. Production account, consent storage, and desktop permission checks are not connected.',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 24),
          _ReadinessRow(
            icon: Icons.person_off_outlined,
            title: 'Authentication unavailable',
            detail: configurationMessage,
            state: 'Unavailable',
          ),
          const SizedBox(height: 10),
          const _ReadinessRow(
            icon: Icons.policy_outlined,
            title: 'Production consent unavailable',
            detail:
                'This preview cannot record consent or process personal data.',
            state: 'Not recorded',
          ),
          const SizedBox(height: 18),
          Material(
            color: Colors.transparent,
            child: CheckboxListTile(
              key: const Key('preview_acknowledgement'),
              contentPadding: EdgeInsets.zero,
              value: acknowledged,
              onChanged: (value) => onAcknowledged(value ?? false),
              title: const Text('I understand this is an unsaved preview'),
              subtitle: const Text(
                'Do not enter sensitive or private information.',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ),
          if (validationMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              validationMessage!,
              key: const Key('onboarding_validation'),
              style: const TextStyle(color: Color(0xffffb4ab)),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const Key('continue_preview_intro'),
            onPressed: acknowledged ? onContinue : null,
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('Continue preview'),
          ),
        ],
      ),
    ),
  );
}

class _ProfileQuestion extends StatelessWidget {
  const _ProfileQuestion({
    required this.prompt,
    required this.index,
    required this.count,
    required this.controller,
    required this.validationMessage,
    required this.onContinue,
    super.key,
  });

  final (String, String, String) prompt;
  final int index;
  final int count;
  final TextEditingController controller;
  final String? validationMessage;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => GlassCard(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PREVIEW QUESTION ${index + 1} OF $count',
            style: const TextStyle(
              color: Color(0xff73d5c4),
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          Text(prompt.$1, style: Theme.of(context).textTheme.displaySmall),
          const SizedBox(height: 12),
          Text(
            prompt.$2,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 28),
          TextField(
            key: const Key('onboarding_input'),
            controller: controller,
            minLines: 2,
            maxLines: 4,
            autofocus: true,
            decoration: InputDecoration(
              hintText: prompt.$3,
              errorText: validationMessage,
              suffixIcon: IconButton(
                key: const Key('continue_onboarding'),
                tooltip: 'Continue',
                onPressed: onContinue,
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ),
            onSubmitted: (_) => onContinue(),
          ),
        ],
      ),
    ),
  );
}

class _ProductionGate extends StatelessWidget {
  const _ProductionGate({
    required this.configurationMessage,
    required this.onOpenPreview,
    super.key,
  });

  final String configurationMessage;
  final VoidCallback onOpenPreview;

  @override
  Widget build(BuildContext context) => GlassCard(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Production setup is not ready.',
            style: Theme.of(context).textTheme.displaySmall,
          ),
          const SizedBox(height: 12),
          Text(
            'Omi will require a real account, recorded data consent, and validated desktop permissions before production onboarding can finish.',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 24),
          _ReadinessRow(
            icon: Icons.person_outline_rounded,
            title: 'Firebase account',
            detail: configurationMessage,
            state: 'Unavailable',
          ),
          const SizedBox(height: 10),
          const _ReadinessRow(
            icon: Icons.policy_outlined,
            title: 'Data and AI consent',
            detail:
                'No production consent receipt can be stored in this build.',
            state: 'Unavailable',
          ),
          const SizedBox(height: 10),
          const _ReadinessRow(
            icon: Icons.desktop_windows_outlined,
            title: 'Core desktop permissions',
            detail:
                'Accessibility, microphone, screen recording, and file access have not been checked.',
            state: 'Not checked',
          ),
          const SizedBox(height: 24),
          const FilledButton(
            key: Key('finish_production_onboarding'),
            onPressed: null,
            child: Text('Finish production setup'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('open_interface_preview'),
            onPressed: onOpenPreview,
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('Open interface preview (demo)'),
          ),
        ],
      ),
    ),
  );
}

class _ReadinessRow extends StatelessWidget {
  const _ReadinessRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.state,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String state;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .18),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: .07)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Colors.white70),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: const TextStyle(color: Colors.white60, height: 1.35),
                ),
                const SizedBox(height: 6),
                Text(state, style: const TextStyle(color: Color(0xffffc66d))),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
