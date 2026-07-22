import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
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
              decoration: const InputDecoration(labelText: 'Verification code'),
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
