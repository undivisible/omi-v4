import 'package:flutter/material.dart';

import '../app_services.dart';
import '../auth/auth.dart';
import '../ui/omi_orb.dart';
import '../ui/omi_typography.dart';
import 'omi_shell.dart';
import 'onboarding/authentication_gate.dart';
import 'setup_account_screens.dart';

/// The web entry point at api.omi.tsc.hk/portal.
///
/// It is the signed-in app, not the demo: sign-in first, then the same hub the
/// desktop build shows. Onboarding is skipped entirely — the setup it drives
/// (screen capture, keyboard, providers on device) has no web counterpart, and
/// an account is created in the desktop or mobile app, never here.
class WebPortalScreen extends StatefulWidget {
  const WebPortalScreen({required this.services, super.key});

  final AppServices services;

  @override
  State<WebPortalScreen> createState() => _WebPortalScreenState();
}

class _WebPortalScreenState extends State<WebPortalScreen> {
  bool _deepLinkOpened = false;

  @override
  void initState() {
    super.initState();
    widget.services.auth.addListener(_authChanged);
  }

  @override
  void dispose() {
    widget.services.auth.removeListener(_authChanged);
    super.dispose();
  }

  void _authChanged() {
    if (mounted) setState(() {});
  }

  /// `/portal#api-keys` and friends. The fragment is the only routing the
  /// portal has, and it is read once: after that the visitor is navigating.
  void _openDeepLink() {
    if (_deepLinkOpened) return;
    final section = portalDeepLinkSection(Uri.base.fragment);
    _deepLinkOpened = true;
    if (section == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => SettingsScreen(
            services: widget.services,
            initialSection: section,
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.services.auth.snapshot.phase != AuthPhase.signedIn) {
      return WebSignInScreen(services: widget.services);
    }
    _openDeepLink();
    return OmiShell(services: widget.services);
  }
}

/// Resolves the URL fragment the marketing site links with to a settings
/// section. `#api-keys` is the published name for what the app calls
/// "API & MCP"; the enum's own names are accepted too.
SettingsSection? portalDeepLinkSection(String fragment) {
  final name = fragment.trim().toLowerCase();
  if (name.isEmpty) return null;
  return switch (name) {
    'api-keys' || 'api' || 'keys' => SettingsSection.developer,
    'billing' || 'plan' => SettingsSection.plan,
    'providers' => SettingsSection.providers,
    _ => SettingsSection.tryParse(name),
  };
}

class WebSignInScreen extends StatelessWidget {
  const WebSignInScreen({required this.services, super.key});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: OmiActivityOrb(size: 56)),
                const SizedBox(height: 24),
                Text(
                  'Sign in to Omi',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontFamily: OmiFonts.sans,
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.6,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Your memory, your settings, your keys — the same hub the '
                  'desktop app opens.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontFamily: OmiFonts.sans,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 28),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    child: AuthenticationGate(
                      auth: services.auth,
                      configurationMessage: services.configurationMessage,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'New accounts are created in the Omi desktop or mobile app. '
                  'Sign in here once you have one.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontFamily: OmiFonts.sans,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
