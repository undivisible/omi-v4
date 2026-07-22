import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../app_services.dart';
import '../auth/auth.dart';
import 'onboarding/authentication_gate.dart';

class DesktopAuthScreen extends StatefulWidget {
  DesktopAuthScreen({
    required AppServices services,
    required this.sessionId,
    super.key,
  }) : auth = services.auth,
       configurationMessage = services.configurationMessage;

  @visibleForTesting
  const DesktopAuthScreen.forTesting({
    required this.auth,
    required this.sessionId,
    this.configurationMessage = 'Test authentication',
    super.key,
  });

  final AuthController auth;
  final String configurationMessage;
  final String sessionId;

  @override
  State<DesktopAuthScreen> createState() => _DesktopAuthScreenState();
}

class _DesktopAuthScreenState extends State<DesktopAuthScreen> {
  final confirmationCode = TextEditingController();
  bool completing = false;
  bool completed = false;
  String? error;

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_authChanged);
    _authChanged();
  }

  @override
  void dispose() {
    widget.auth.removeListener(_authChanged);
    confirmationCode.dispose();
    super.dispose();
  }

  void _authChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _complete() async {
    if (!mounted || completing) return;
    setState(() {
      completing = true;
      error = null;
    });
    final origin = AppServices.apiOrigin();
    final code = confirmationCode.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() {
        completing = false;
        error = 'Enter the 6-digit code shown in the desktop app.';
      });
      return;
    }
    try {
      final session = await widget.auth.handoffSession();
      if (origin.isEmpty || session == null) {
        throw const AuthOperationException(
          AuthFailure(
            AuthErrorCode.configurationMissing,
            'Desktop handoff is not configured.',
          ),
        );
      }
      final response = await http
          .post(
            Uri.parse(origin).resolve('/v1/auth/desktop/complete'),
            headers: {
              'authorization': 'Bearer ${session.idToken}',
              'content-type': 'application/json',
            },
            body: jsonEncode({
              'sessionId': widget.sessionId,
              'confirmationCode': code,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        final body = jsonDecode(response.body);
        throw StateError(
          body is Map && body['error'] is String
              ? body['error'] as String
              : 'Could not complete desktop sign-in',
        );
      }
      if (mounted) setState(() => completed = true);
    } on AuthGatewayException catch (failure) {
      if (mounted) setState(() => error = failure.failure.message);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not complete desktop sign-in. Retry.');
      }
    } finally {
      if (mounted) setState(() => completing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: completed
                      ? Semantics(
                          liveRegion: true,
                          label:
                              'Desktop sign-in complete. You can close this browser tab and return to Omi.',
                          excludeSemantics: true,
                          child: const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle_rounded, size: 52),
                              SizedBox(height: 16),
                              Text('Desktop sign-in complete'),
                              SizedBox(height: 8),
                              Text(
                                'You can close this browser tab and return to Omi.',
                              ),
                            ],
                          ),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Continue to Omi desktop',
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Sign in here. Your Firebase password or SMS code never passes through the desktop handoff service.',
                            ),
                            const SizedBox(height: 20),
                            AuthenticationGate(
                              auth: widget.auth,
                              configurationMessage: widget.configurationMessage,
                            ),
                            if (widget.auth.snapshot.phase ==
                                AuthPhase.signedIn) ...[
                              const SizedBox(height: 16),
                              TextField(
                                controller: confirmationCode,
                                keyboardType: TextInputType.number,
                                maxLength: 6,
                                autofillHints: const [
                                  AutofillHints.oneTimeCode,
                                ],
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                textInputAction: TextInputAction.done,
                                decoration: const InputDecoration(
                                  labelText: 'Desktop confirmation code',
                                ),
                                onSubmitted: completing
                                    ? null
                                    : (_) => _complete(),
                              ),
                              FilledButton(
                                onPressed: completing ? null : _complete,
                                child: const Text('Confirm this desktop'),
                              ),
                            ],
                            if (completing) ...[
                              const SizedBox(height: 16),
                              Semantics(
                                liveRegion: true,
                                label: 'Completing desktop sign-in',
                                child: LinearProgressIndicator(),
                              ),
                            ],
                            if (error != null) ...[
                              const SizedBox(height: 12),
                              Semantics(
                                liveRegion: true,
                                label: 'Desktop sign-in error. $error',
                                excludeSemantics: true,
                                child: Text(
                                  error!,
                                  style: const TextStyle(
                                    color: Color(0xffffb4ab),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
