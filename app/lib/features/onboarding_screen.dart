import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../auth/auth.dart';
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
    widget.services.auth.addListener(_refresh);
  }

  @override
  void dispose() {
    onboarding.removeListener(_refresh);
    widget.services.auth.removeListener(_refresh);
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
                          auth: widget.services.auth,
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
    required this.auth,
    required this.onOpenPreview,
    super.key,
  });

  final String configurationMessage;
  final AuthController auth;
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
          AuthenticationGate(
            auth: auth,
            configurationMessage: configurationMessage,
          ),
          const SizedBox(height: 10),
          ProcessingConsentGate(auth: auth),
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

class ProcessingConsentGate extends StatelessWidget {
  const ProcessingConsentGate({required this.auth, super.key});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final snapshot = auth.snapshot;
    final granted = snapshot.hasProcessingAuthority;
    final signedIn = snapshot.phase == AuthPhase.signedIn;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: .07)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Omi processing consent',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              'Allow Omi to process your conversations, screen context, device audio, and connected-service data for memory and assistant features. This versioned consent can be revoked at any time.',
              style: TextStyle(color: Colors.white60, height: 1.35),
            ),
            const SizedBox(height: 12),
            if (!granted)
              FilledButton(
                key: const Key('grant_processing_consent'),
                onPressed: signedIn
                    ? () => unawaited(auth.grantProcessingConsent())
                    : null,
                child: Text(
                  signedIn
                      ? 'Grant processing consent v1'
                      : 'Sign in before granting consent',
                ),
              )
            else
              OutlinedButton(
                key: const Key('revoke_processing_consent'),
                onPressed: () => unawaited(auth.revokeProcessingConsent()),
                child: const Text('Revoke processing consent'),
              ),
          ],
        ),
      ),
    );
  }
}

class AuthenticationGate extends StatefulWidget {
  const AuthenticationGate({
    required this.auth,
    required this.configurationMessage,
    super.key,
  });

  final AuthController auth;
  final String configurationMessage;

  @override
  State<AuthenticationGate> createState() => _AuthenticationGateState();
}

class _AuthenticationGateState extends State<AuthenticationGate> {
  final phone = TextEditingController();
  final code = TextEditingController();
  bool phoneDisclosureAcknowledged = false;

  @override
  void dispose() {
    phone.dispose();
    code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.auth.snapshot;
    if (snapshot.phase == AuthPhase.signedIn) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ReadinessRow(
            icon: Icons.verified_user_outlined,
            title: 'Firebase account',
            detail:
                snapshot.session?.phoneNumber ??
                snapshot.session?.email ??
                snapshot.session!.uid,
            state: 'Signed in',
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('sign_out_firebase'),
            onPressed: () => unawaited(widget.auth.signOut()),
            child: const Text('Sign out'),
          ),
        ],
      );
    }
    if (snapshot.phase == AuthPhase.unavailable) {
      return _ReadinessRow(
        icon: Icons.person_off_outlined,
        title: 'Firebase account',
        detail: widget.configurationMessage,
        state: 'Unavailable',
      );
    }
    final busy = {
      AuthPhase.requestingOtp,
      AuthPhase.signingIn,
      AuthPhase.signingOut,
    }.contains(snapshot.phase);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: .07)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Firebase account',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            Material(
              color: Colors.transparent,
              child: CheckboxListTile(
                key: const Key('firebase_auth_acknowledgement'),
                contentPadding: EdgeInsets.zero,
                value: snapshot.consentGranted,
                onChanged: busy
                    ? null
                    : (value) =>
                          unawaited(widget.auth.setConsent(value ?? false)),
                title: const Text('I agree to Firebase account authentication'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ),
            if (snapshot.phase == AuthPhase.awaitingOtp) ...[
              TextField(
                key: const Key('auth_otp'),
                controller: code,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Verification code',
                ),
                onSubmitted: busy
                    ? null
                    : (_) => widget.auth.confirmPhoneOtp(code.text),
              ),
              const SizedBox(height: 10),
              FilledButton(
                key: const Key('confirm_phone_otp'),
                onPressed: busy
                    ? null
                    : () => widget.auth.confirmPhoneOtp(code.text),
                child: const Text('Verify phone'),
              ),
            ] else ...[
              if (widget.auth.supportsPhoneOtp) ...[
                const Text(
                  'For abuse prevention, Firebase sends your phone number to Google and Google stores it under its authentication terms.',
                ),
                Material(
                  color: Colors.transparent,
                  child: CheckboxListTile(
                    key: const Key('firebase_phone_disclosure'),
                    contentPadding: EdgeInsets.zero,
                    value: phoneDisclosureAcknowledged,
                    onChanged: busy
                        ? null
                        : (value) => setState(
                            () => phoneDisclosureAcknowledged = value ?? false,
                          ),
                    title: const Text(
                      'I understand this Firebase phone-number disclosure',
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('auth_phone'),
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  textInputAction: TextInputAction.send,
                  decoration: const InputDecoration(
                    labelText: 'Phone number',
                    hintText: '+1 555 555 0123',
                  ),
                  onSubmitted:
                      busy ||
                          !snapshot.consentGranted ||
                          !phoneDisclosureAcknowledged
                      ? null
                      : (_) => widget.auth.requestPhoneOtp(phone.text),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  key: const Key('request_phone_otp'),
                  onPressed:
                      busy ||
                          !snapshot.consentGranted ||
                          !phoneDisclosureAcknowledged
                      ? null
                      : () => widget.auth.requestPhoneOtp(phone.text),
                  child: const Text('Text me a code'),
                ),
              ] else if (widget.auth.supportsDesktopBrowserHandoff) ...[
                const Text(
                  'Phone verification opens in your browser. The browser returns a one-time Firebase sign-in token only to this desktop.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Completing browser sign-in does not grant Omi processing consent. You will review that separately after returning to Omi.',
                ),
                CheckboxListTile(
                  key: const Key('firebase_phone_disclosure'),
                  contentPadding: EdgeInsets.zero,
                  value: phoneDisclosureAcknowledged,
                  onChanged: busy
                      ? null
                      : (value) => setState(
                          () => phoneDisclosureAcknowledged = value ?? false,
                        ),
                  title: const Text(
                    'I understand Firebase sends my phone number to Google for abuse prevention',
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                FilledButton.icon(
                  key: const Key('desktop_browser_sign_in'),
                  onPressed:
                      busy ||
                          !snapshot.consentGranted ||
                          !phoneDisclosureAcknowledged
                      ? null
                      : () => widget.auth.signInWithDesktopBrowser(),
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: const Text('Continue securely in browser'),
                ),
                if (widget.auth.desktopConfirmationCode case final code?) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    code,
                    key: const Key('desktop_confirmation_code'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const Text(
                    'Enter this code in the browser to confirm it is your desktop.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ] else
                const _ReadinessRow(
                  icon: Icons.phone_disabled_outlined,
                  title: 'Phone sign-in',
                  detail: 'Secure browser handoff is not configured.',
                  state: 'Unavailable',
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('sign_in_google'),
                      onPressed: busy || !snapshot.consentGranted
                          ? null
                          : () => widget.auth.signIn(AuthProvider.google),
                      child: const Text('Google'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('sign_in_apple'),
                      onPressed: busy || !snapshot.consentGranted
                          ? null
                          : () => widget.auth.signIn(AuthProvider.apple),
                      child: const Text('Apple'),
                    ),
                  ),
                ],
              ),
            ],
            if (busy)
              Semantics(
                liveRegion: true,
                label: 'Authentication in progress',
                child: SizedBox.shrink(),
              ),
            if (snapshot.failure case final failure?) ...[
              const SizedBox(height: 10),
              Semantics(
                liveRegion: true,
                label: 'Authentication error. ${failure.message}',
                excludeSemantics: true,
                child: Text(
                  failure.message,
                  key: const Key('auth_failure'),
                  style: const TextStyle(color: Color(0xffffb4ab)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
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
