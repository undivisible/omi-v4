import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/dev_assistant.dart';
import '../app_services.dart';
import '../auth/auth.dart';
import '../conversations/conversations.dart';
import '../currents/currents.dart';
import '../device/device.dart';
import '../features/meeting_notes.dart';
import '../features/setup_account_screens.dart';
import '../onboarding/onboarding_completion.dart';
import 'demo_currents_transport.dart';
import 'demo_mode.dart';
import 'demo_native_hub.dart';
import 'demo_seed.dart';

/// Boots the public demo: the real [AppServices] and the real shell, wired to
/// seeded, in-process stand-ins for everything that would otherwise be a
/// network call.
///
/// Nothing here reaches the network. Auth is [UnconfiguredAuthGateway], so no
/// Firebase client is constructed and no sign-in is attempted; there is no
/// [WorkerHttpClient], so there is no origin to call; currents come from
/// [DemoCurrentsTransport]; the assistant comes from [DemoNativeHub]. The
/// preference store is the in-memory one, so the demo does not write to the
/// visitor's localStorage either.
Future<void> runOmiDemo(Widget Function(AppServices services) buildApp) async {
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues(demoPreferences());
  final services = await createDemoServices();
  runApp(buildApp(services));
}

Future<AppServices> createDemoServices() async {
  // The no-account path the demo rides is gated on the hub having resolved a
  // developer key. There is no key and no hub here, so the documented test
  // seam declares one: it is a marker that unlocks the local path, and
  // [DemoNativeHub] answers every message from the seed without it.
  debugDevAssistantAccess = const DevAssistantAccess(
    credential: 'omi-demo-seeded-no-model',
    liveModel: '',
    missingKeyHint: '',
  );
  final conversation = VolatileLocalConversationStore();
  for (final turn in demoConversation) {
    await conversation.append(
      clientMessageId:
          'demo-${turn.role}-${conversation.hashCode}-'
          '${turn.text.hashCode}',
      role: turn.role,
      source: 'web',
      text: turn.text,
    );
  }
  final services = AppServices.forTesting(
    nativeHub: DemoNativeHub(),
    deviceRelay: DeviceRelayService(
      role: DeviceRelayRole.desktopObserver,
      adapter: const UnavailableDeviceRelayAdapter(),
    ),
    auth: AuthController(const UnconfiguredAuthGateway()),
    memoryDatabasePath: (uid) => 'demo-memory-$uid',
    localConversations: conversation,
    currentsClient: CurrentsClient(DemoCurrentsTransport()),
    configurationMessage:
        'Demo mode — no account is connected. Open Omi to sign in.',
  );
  final notes = VolatileMeetingNotesStore();
  for (final note in demoMeetingNotes().reversed) {
    await notes.save(note);
  }
  services.meetingNotes = notes;
  await services.initialize();
  return services;
}

/// Onboarding is already done, always.
///
/// Onboarding's first step is the private workspace scan, which needs the
/// native hub and so cannot run in a browser; the web target consequently
/// opens on a sign-in prompt. The demo has no account to sign into, so it
/// declares the local profile complete and goes straight to the shell.
OnboardingCompletionStore demoOnboardingCompletion() =>
    VolatileOnboardingCompletionStore()..completedUids.add(localOnboardingUid);

/// The persistent "this is a demo" strip.
///
/// It is mounted through `MaterialApp.builder`, so it sits above every route —
/// including settings and meeting notes — and cannot be navigated away from.
/// A visitor is never shown seeded content without this on screen.
class DemoBanner extends StatelessWidget {
  const DemoBanner({
    required this.services,
    required this.navigator,
    required this.child,
    super.key,
  });

  final AppServices services;
  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xfff4f2ea) : const Color(0xff171716);
    final muted = dark ? const Color(0xffa6a49c) : const Color(0xff706e68);
    final compact = MediaQuery.sizeOf(context).width < 560;
    return Column(
      key: const Key('demo_banner_host'),
      children: [
        Material(
          color: dark ? const Color(0xff232321) : const Color(0xfff0eee6),
          child: SafeArea(
            bottom: false,
            child: Semantics(
              container: true,
              label:
                  'Demo. Sample data only. Nothing you do here leaves your '
                  'browser.',
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: muted),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        'DEMO',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.9,
                          color: ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        compact
                            ? 'Sample data. Not your account.'
                            : 'Sample data, not your account. Nothing you '
                                  'type here leaves your browser, and no '
                                  'model is called.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.25,
                          color: muted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Settings live in a native window on macOS and have no
                    // entry point at all on the web target, so the demo opens
                    // the real settings route from here.
                    TextButton(
                      key: const Key('demo_open_settings'),
                      onPressed: _openSettings,
                      style: TextButton.styleFrom(
                        foregroundColor: muted,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 32),
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('Settings'),
                    ),
                    const SizedBox(width: 4),
                    TextButton(
                      key: const Key('demo_open_omi'),
                      onPressed: _openOmi,
                      style: TextButton.styleFrom(
                        foregroundColor: ink,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(0, 32),
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('Open Omi'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }

  void _openSettings() {
    navigator.currentState?.push(
      MaterialPageRoute<void>(
        builder: (context) => SettingsScreen(services: services),
      ),
    );
  }

  /// The demo runs inside an iframe on the marketing site, so the real app has
  /// to open in the top-level document rather than inside the frame.
  void _openOmi() {
    unawaited(
      launchUrl(
        Uri.base.resolve(demoSignInUrl),
        webOnlyWindowName: '_top',
      ).then((_) {}, onError: (Object _) {}),
    );
  }
}
