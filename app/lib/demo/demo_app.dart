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
import 'demo_model.dart';
import 'demo_native_hub.dart';
import 'demo_seed.dart';
import 'demo_tour.dart';

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
  // Asks the browser what it can run before the first frame. This only reads
  // capabilities — it does not download a model whatever the answer is.
  unawaited(DemoModel.instance.resolve());
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
/// A visitor is never shown seeded content without this on screen. The tour
/// panel is *not* here: it rides the navigator's overlay instead (see
/// [DemoTourOverlay]), because a widget hosted above the navigator by
/// `MaterialApp.builder` does not repaint on its own `setState` in a release
/// web build.
class DemoBanner extends StatefulWidget {
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
  State<DemoBanner> createState() => _DemoBannerState();
}

class _DemoBannerState extends State<DemoBanner> {
  bool _settingsOpen = false;

  Future<void> _toggleSettings() async {
    if (_settingsOpen) {
      widget.navigator.currentState?.pop();
      return;
    }
    setState(() => _settingsOpen = true);
    await widget.navigator.currentState?.push<void>(
      MaterialPageRoute<void>(
        builder: (context) => SettingsScreen(services: widget.services),
      ),
    );
    if (mounted) setState(() => _settingsOpen = false);
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

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xfff4f2ea) : const Color(0xff171716);
    final muted = dark ? const Color(0xffa6a49c) : const Color(0xff706e68);
    final compact =
        MediaQuery.sizeOf(context).width < 560 ||
        MediaQuery.sizeOf(context).height < 640;
    return Column(
      key: const Key('demo_banner_host'),
      children: [
        Material(
          color: Colors.transparent,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: dark
                    ? const [Color(0xff2c2927), Color(0xff232321)]
                    : const [Color(0xffeadbc7), Color(0xffdce2d5)],
              ),
              border: Border(
                bottom: BorderSide(color: ink.withValues(alpha: .09)),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Semantics(
                container: true,
                label:
                    'Demo. Sample data only. Nothing you do here leaves your '
                    'browser.',
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: ink.withValues(alpha: .06),
                          border: Border.all(color: ink.withValues(alpha: .12)),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'DEMO',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.1,
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
                                    'type here leaves your browser.',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.25,
                            color: muted,
                          ),
                        ),
                      ),
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
                        child: Text(compact ? 'Open' : 'Open Omi'),
                      ),
                      const SizedBox(width: 2),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: _settingsOpen
                              ? ink.withValues(alpha: .12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _settingsOpen
                                ? ink.withValues(alpha: .22)
                                : Colors.transparent,
                          ),
                        ),
                        child: Semantics(
                          button: true,
                          label: _settingsOpen ? 'Close settings' : 'Settings',
                          child: InkWell(
                            key: const Key('demo_open_settings'),
                            onTap: _toggleSettings,
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Icon(
                                Icons.tune_rounded,
                                size: 18,
                                color: _settingsOpen ? ink : muted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // The shell. The tour panel is not stacked here — it rides the
        // navigator's overlay (see [DemoTourOverlay]) so it repaints when the
        // visitor takes a step, which a widget hosted above the navigator here
        // would not do in a release web build.
        Expanded(child: widget.child),
      ],
    );
  }
}
