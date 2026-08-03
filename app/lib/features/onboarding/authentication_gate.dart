import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_services.dart';
import '../../auth/auth.dart';

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
  final code = TextEditingController();
  String? _clipboardNote;

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  /// Pasting is the other way in, and on a phone it is the usual one: the code
  /// arrives in Messages or Telegram and is copied from there. Redeem a clean
  /// paste immediately rather than making the user press a second button.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final normalized = normalizeSignInCode(data?.text ?? '');
    if (normalized == null) {
      setState(
        () => _clipboardNote =
            'The clipboard does not hold a sign-in code. Copy the seven '
            'characters the bot sent.',
      );
      return;
    }
    code.text = normalized;
    setState(() => _clipboardNote = null);
    await widget.auth.signInWithChannelCode(normalized);
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
            title: 'Omi account',
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
        title: 'Omi account',
        detail: widget.configurationMessage,
        state: 'Unavailable',
      );
    }
    final busy = {
      AuthPhase.requestingOtp,
      AuthPhase.signingIn,
      AuthPhase.signingOut,
    }.contains(snapshot.phase);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Omi account',
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
              title: const Text('I agree to Omi account authentication'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ),
          if (widget.auth.supportsChannelCode) ...[
            Text(
              _clipboardNote ??
                  'Ask Omi for a sign-in code: text '
                      '${AppServices.messagingNumber()}, or message '
                      '${AppServices.telegramHandle()} on Telegram, and say '
                      '"send me a sign-in code". It replies with seven '
                      'characters — paste them in or type them.',
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('auth_channel_code'),
              controller: code,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.oneTimeCode],
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Sign-in code',
                hintText: signInCodeExample,
                suffixIcon: IconButton(
                  key: const Key('paste_channel_code'),
                  tooltip: 'Paste code',
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  onPressed: busy || !snapshot.consentGranted
                      ? null
                      : () => unawaited(_paste()),
                ),
              ),
              onSubmitted: busy || !snapshot.consentGranted
                  ? null
                  : (_) =>
                        unawaited(widget.auth.signInWithChannelCode(code.text)),
            ),
            const SizedBox(height: 10),
            FilledButton(
              key: const Key('redeem_channel_code'),
              onPressed: busy || !snapshot.consentGranted
                  ? null
                  : () =>
                        unawaited(widget.auth.signInWithChannelCode(code.text)),
              child: const Text('Sign in'),
            ),
          ] else
            const _ReadinessRow(
              icon: Icons.person_off_outlined,
              title: 'Sign-in',
              detail: 'No sign-in method is configured.',
              state: 'Unavailable',
            ),
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 13),
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
  );
}
