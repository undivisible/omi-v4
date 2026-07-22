import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../auth/auth.dart';
import '../device/device.dart';
import 'onboarding/authentication_gate.dart';
import 'onboarding/backdrop.dart';
import 'onboarding/lightspeed.dart';
import 'onboarding/randomized_text.dart';

enum MobileOnboardingStage { account, pair, teach, finish }

const _headingStyle = TextStyle(
  color: Color(0xfffffcec),
  fontFamily: 'Avenir Next',
  fontSize: 30,
  fontWeight: FontWeight.w500,
  height: 1.2,
  letterSpacing: -1,
);
const _headingZoneHeight = 72.0;

class MobileOnboardingScreen extends StatefulWidget {
  const MobileOnboardingScreen({
    required this.services,
    required this.onFinish,
    this.pairedDevices,
    super.key,
  });

  final AppServices services;
  final PairedDeviceStore? pairedDevices;
  final FutureOr<void> Function() onFinish;

  @override
  State<MobileOnboardingScreen> createState() => _MobileOnboardingScreenState();
}

class _MobileOnboardingScreenState extends State<MobileOnboardingScreen> {
  static const _cream = Color(0xfffffcec);
  static const _ink = Color(0xff171716);

  late final PairedDeviceStore _pairedDevices =
      widget.pairedDevices ?? PreferencesPairedDeviceStore();
  MobileOnboardingStage stage = MobileOnboardingStage.account;
  int teachPage = 0;
  bool finishing = false;
  String? finishError;
  LightspeedMode? transitionMode;
  DeviceRelaySnapshot? relaySnapshot;
  StreamSubscription<DeviceRelaySnapshot>? _relaySubscription;

  @override
  void initState() {
    super.initState();
    widget.services.auth.addListener(_refresh);
    _relaySubscription = widget.services.deviceRelay.snapshots.listen((next) {
      if (mounted) setState(() => relaySnapshot = next);
    });
  }

  @override
  void dispose() {
    unawaited(_relaySubscription?.cancel());
    widget.services.auth.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() => setState(() {});

  // Firebase can be entirely unconfigured (local/testing builds with no
  // backend); there is no sign-in flow to satisfy in that case, so don't
  // block forever waiting for processing authority that can never arrive.
  bool get _authSatisfied =>
      widget.services.auth.snapshot.phase == AuthPhase.unavailable ||
      widget.services.auth.snapshot.hasProcessingAuthority;

  void _advance(MobileOnboardingStage next) => setState(() => stage = next);

  // Returning users already have an account (and its memory/profile) on the
  // backend. Skip the device-pairing step (the closest mobile equivalent of
  // the fresh on-device scan desktop skips) and go straight to the short
  // tutorial, while eagerly resyncing their existing data instead of
  // lazily waiting on the next auth change.
  void _useReturningUserFlow() {
    unawaited(widget.services.resyncAccount().onError((_, _) {}));
    _advance(MobileOnboardingStage.teach);
  }

  // Worker-side memory counts are not reachable from this screen without a
  // network round-trip, so desktop data is inferred from the honest local
  // signal: a pendant connected right now plus granted processing authority.
  bool get _desktopDataLikely =>
      relaySnapshot?.phase == DeviceConnectionPhase.connected &&
      widget.services.auth.snapshot.hasProcessingAuthority;

  void _finish() {
    if (finishing || transitionMode != null) return;
    setState(() {
      finishError = null;
      transitionMode = _desktopDataLikely
          ? LightspeedMode.lightspeed
          : LightspeedMode.fade;
    });
  }

  Future<void> _completeFinish() async {
    if (finishing) return;
    setState(() {
      finishing = true;
      finishError = null;
    });
    try {
      await widget.onFinish();
      if (mounted) setState(() => finishing = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        finishing = false;
        transitionMode = null;
        finishError = 'I couldn’t save your setup. Try again.';
      });
    }
  }

  static ButtonStyle get _stadium => FilledButton.styleFrom(
    minimumSize: const Size(0, 56),
    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
    backgroundColor: _cream,
    foregroundColor: _ink,
    shape: const StadiumBorder(),
    textStyle: const TextStyle(
      fontFamily: 'Avenir Next',
      fontSize: 16,
      fontWeight: FontWeight.w600,
    ),
  );

  double get _stageProgress => switch (stage) {
    MobileOnboardingStage.account => 0,
    MobileOnboardingStage.pair => .35,
    MobileOnboardingStage.teach =>
      .6 + .1 * (teachPage / (_TeachStage.pages.length - 1)),
    MobileOnboardingStage.finish => 1,
  };

  @override
  Widget build(BuildContext context) {
    if (transitionMode case final mode?) {
      final darkHome =
          MediaQuery.platformBrightnessOf(context) == Brightness.dark;
      return Scaffold(
        backgroundColor: const Color(0xff171716),
        body: LightspeedTransition(
          key: const Key('mobile_onboarding_transition'),
          mode: mode,
          endColor: darkHome ? _ink : const Color(0xfff7f6f1),
          onCompleted: () => unawaited(_completeFinish()),
          child: mode == LightspeedMode.lightspeed
              ? const PendantVisual(size: 132)
              : null,
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: OnboardingBackdrop(
        baseColor: _ink,
        bright: stage.index >= MobileOnboardingStage.pair.index,
        searching:
            stage == MobileOnboardingStage.pair &&
            relaySnapshot?.phase == DeviceConnectionPhase.scanning,
        settled: stage.index >= MobileOnboardingStage.teach.index,
        progress: _stageProgress,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 24,
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  transitionBuilder: (child, animation) {
                    final eased = CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    );
                    return FadeTransition(
                      opacity: eased,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, .015),
                          end: Offset.zero,
                        ).animate(eased),
                        child: child,
                      ),
                    );
                  },
                  child: switch (stage) {
                    MobileOnboardingStage.account => _AccountStage(
                      key: const ValueKey('mobile_account'),
                      auth: widget.services.auth,
                      configurationMessage:
                          widget.services.configurationMessage,
                      satisfied: _authSatisfied,
                      buttonStyle: _stadium,
                      onContinue: () => _advance(MobileOnboardingStage.pair),
                      onAlreadyHaveAccount: _useReturningUserFlow,
                    ),
                    MobileOnboardingStage.pair => _PairStage(
                      key: const ValueKey('mobile_pair'),
                      services: widget.services,
                      pairedDevices: _pairedDevices,
                      buttonStyle: _stadium,
                      onContinue: () => _advance(MobileOnboardingStage.teach),
                    ),
                    MobileOnboardingStage.teach => _TeachStage(
                      key: ValueKey('mobile_teach_$teachPage'),
                      page: teachPage,
                      buttonStyle: _stadium,
                      onContinue: () {
                        if (teachPage < _TeachStage.pages.length - 1) {
                          setState(() => teachPage += 1);
                        } else {
                          _advance(MobileOnboardingStage.finish);
                        }
                      },
                    ),
                    MobileOnboardingStage.finish => _FinishStage(
                      key: const ValueKey('mobile_finish'),
                      finishing: finishing,
                      error: finishError,
                      buttonStyle: _stadium,
                      onFinish: _finish,
                    ),
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StageLayout extends StatelessWidget {
  const _StageLayout({
    required this.heading,
    required this.primary,
    this.body,
    this.secondary,
  });

  final Widget heading;
  final Widget? body;
  final Widget primary;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        height: _headingZoneHeight,
        child: ClipRect(
          child: Align(alignment: Alignment.bottomLeft, child: heading),
        ),
      ),
      const SizedBox(height: 20),
      Expanded(
        child: SingleChildScrollView(child: body ?? const SizedBox.shrink()),
      ),
      const SizedBox(height: 18),
      SizedBox(
        key: const Key('mobile_onboarding_primary_slot'),
        height: 56,
        child: Center(child: primary),
      ),
      SizedBox(
        height: 52,
        child: Center(child: secondary ?? const SizedBox.shrink()),
      ),
    ],
  );
}

class PendantVisual extends StatelessWidget {
  const PendantVisual({required this.size, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size * 1.9,
    height: size * 1.9,
    child: Stack(
      alignment: Alignment.center,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                const Color(0xfff2c2ac).withValues(alpha: .38),
                const Color(0xff96c4ff).withValues(alpha: .12),
                Colors.transparent,
              ],
              stops: const [0, .55, 1],
            ),
          ),
          child: SizedBox(width: size * 1.9, height: size * 1.9),
        ),
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xff1f1f1d),
            border: Border.all(color: const Color(0x59fffcec), width: 1.4),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Center(
            child: Container(
              width: size * .3,
              height: size * .3,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0xfffffcec), Color(0xfff2c2ac)],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _AccountStage extends StatelessWidget {
  const _AccountStage({
    required this.auth,
    required this.configurationMessage,
    required this.satisfied,
    required this.buttonStyle,
    required this.onContinue,
    required this.onAlreadyHaveAccount,
    super.key,
  });

  final AuthController auth;
  final String configurationMessage;
  final bool satisfied;
  final ButtonStyle buttonStyle;
  final VoidCallback onContinue;
  final VoidCallback onAlreadyHaveAccount;

  @override
  Widget build(BuildContext context) => _StageLayout(
    heading: const RandomizedText(
      segments: [
        ('Hi, I’m Omi. Let’s set up your ', null),
        ('pendant.', TextStyle(fontWeight: FontWeight.w700)),
      ],
      maxLines: 2,
      style: _headingStyle,
    ),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AuthenticationGate(
          auth: auth,
          configurationMessage: configurationMessage,
        ),
        if (auth.snapshot.phase == AuthPhase.signedIn &&
            !auth.snapshot.hasProcessingAuthority) ...[
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('mobile_grant_processing_consent'),
            onPressed: () => unawaited(auth.grantProcessingConsent()),
            child: const Text('Allow Omi to process my data'),
          ),
        ],
      ],
    ),
    primary: FilledButton(
      key: const Key('mobile_onboarding_account_continue'),
      onPressed: satisfied ? onContinue : null,
      style: buttonStyle,
      child: const Text('Continue'),
    ),
    secondary: TextButton(
      key: const Key('mobile_already_have_account'),
      style: TextButton.styleFrom(
        foregroundColor: const Color(0xb3fffcec),
        textStyle: const TextStyle(
          fontFamily: 'Avenir Next',
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      onPressed: onAlreadyHaveAccount,
      child: const Text('Already have an account?'),
    ),
  );
}

class _PairStage extends StatefulWidget {
  const _PairStage({
    required this.services,
    required this.pairedDevices,
    required this.buttonStyle,
    required this.onContinue,
    super.key,
  });

  final AppServices services;
  final PairedDeviceStore pairedDevices;
  final ButtonStyle buttonStyle;
  final VoidCallback onContinue;

  @override
  State<_PairStage> createState() => _PairStageState();
}

class _PairStageState extends State<_PairStage> {
  late final DeviceRelayService relay = widget.services.deviceRelay;
  List<RelayDevice> devices = const [];
  DeviceRelaySnapshot? snapshot;
  Object? error;
  StreamSubscription<DeviceRelaySnapshot>? _snapshotSubscription;

  DeviceConnectionPhase get _phase =>
      snapshot?.phase ?? DeviceConnectionPhase.disconnected;

  bool get _connected => _phase == DeviceConnectionPhase.connected;

  @override
  void initState() {
    super.initState();
    _snapshotSubscription = relay.snapshots.listen((next) {
      if (mounted) setState(() => snapshot = next);
    });
  }

  @override
  void dispose() {
    unawaited(_snapshotSubscription?.cancel());
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => error = null);
    try {
      final found = await relay.scan();
      if (mounted) setState(() => devices = found);
    } catch (next) {
      if (mounted) setState(() => error = next);
    }
  }

  Future<void> _connect(RelayDevice device) async {
    setState(() => error = null);
    try {
      await widget.services.connectDevice(device.id);
      await widget.pairedDevices.save(device.id);
      unawaited(relay.sendHaptic(2));
      if (mounted) setState(() {});
    } catch (next) {
      if (mounted) setState(() => error = next);
    }
  }

  String _phaseLabel(DeviceConnectionPhase phase) => switch (phase) {
    DeviceConnectionPhase.unavailable => 'Unavailable',
    DeviceConnectionPhase.disconnected => 'Not connected yet',
    DeviceConnectionPhase.scanning => 'Scanning…',
    DeviceConnectionPhase.connecting => 'Connecting…',
    DeviceConnectionPhase.connected => 'Connected',
    DeviceConnectionPhase.disconnecting => 'Disconnecting…',
    DeviceConnectionPhase.failed => 'Connection failed',
  };

  @override
  Widget build(BuildContext context) => _StageLayout(
    heading: const RandomizedText(
      segments: [('Pair your pendant.', null)],
      maxLines: 2,
      style: _headingStyle,
    ),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: PendantVisual(size: 110)),
        const SizedBox(height: 8),
        Text(
          [_phaseLabel(_phase), ?snapshot?.message].join(' · '),
          key: const Key('mobile_pair_status'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xffd0cec6), height: 1.4),
        ),
        const SizedBox(height: 18),
        if (!_connected) ...[
          OutlinedButton.icon(
            key: const Key('mobile_pair_scan'),
            onPressed: _phase == DeviceConnectionPhase.scanning ? null : _scan,
            icon: const Icon(Icons.bluetooth_searching_rounded),
            label: const Text('Scan for my Omi'),
          ),
          const SizedBox(height: 8),
          for (final found in devices)
            ListTile(
              key: Key('mobile_pair_connect_${found.id}'),
              leading: const Icon(
                Icons.watch_outlined,
                color: Color(0xfffffcec),
              ),
              title: Text(
                found.name,
                style: const TextStyle(color: Color(0xfffffcec)),
              ),
              subtitle: Text(
                [
                  if (found.signalStrength case final signal?) '$signal dBm',
                  if (found.batteryLevel case final battery?)
                    '$battery% battery',
                ].join(' · '),
                style: const TextStyle(color: Color(0xffd0cec6)),
              ),
              trailing: const Icon(
                Icons.add_circle_outline_rounded,
                color: Color(0xfffffcec),
              ),
              onTap: _phase == DeviceConnectionPhase.connecting
                  ? null
                  : () => unawaited(_connect(found)),
            ),
        ],
        if (error case final message?) ...[
          const SizedBox(height: 8),
          Text('$message', style: const TextStyle(color: Color(0xffffb4ab))),
        ],
      ],
    ),
    primary: _connected
        ? FilledButton(
            key: const Key('mobile_pair_continue'),
            onPressed: widget.onContinue,
            style: widget.buttonStyle,
            child: const Text('Continue'),
          )
        : FilledButton(
            key: const Key('mobile_pair_continue_disabled'),
            onPressed: null,
            style: widget.buttonStyle,
            child: const Text('Continue'),
          ),
    secondary: _connected
        ? null
        : TextButton(
            key: const Key('mobile_pair_skip'),
            onPressed: widget.onContinue,
            child: const Text('Pair later'),
          ),
  );
}

class _TeachStage extends StatelessWidget {
  const _TeachStage({
    required this.page,
    required this.buttonStyle,
    required this.onContinue,
    super.key,
  });

  static const pages = [
    'Wear your pendant and it captures your conversations as you go.',
    'The capture toggle and battery live on the home screen — pause any time.',
    'Transcripts land in your memory, ready on desktop and Telegram.',
  ];

  final int page;
  final ButtonStyle buttonStyle;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => _StageLayout(
    heading: RandomizedText(
      key: ValueKey(pages[page]),
      segments: [(pages[page], null)],
      maxLines: 2,
      style: _headingStyle.copyWith(fontSize: 24, letterSpacing: -.5),
    ),
    primary: FilledButton(
      key: Key('mobile_teach_continue_$page'),
      onPressed: onContinue,
      style: buttonStyle,
      child: Text(page < pages.length - 1 ? 'Next' : 'Got it'),
    ),
  );
}

class _FinishStage extends StatelessWidget {
  const _FinishStage({
    required this.finishing,
    required this.error,
    required this.buttonStyle,
    required this.onFinish,
    super.key,
  });

  final bool finishing;
  final String? error;
  final ButtonStyle buttonStyle;
  final FutureOr<void> Function() onFinish;

  @override
  Widget build(BuildContext context) => _StageLayout(
    heading: const RandomizedText(
      segments: [('You’re all set.', null)],
      maxLines: 2,
      style: _headingStyle,
    ),
    body: const Center(child: PendantVisual(size: 120)),
    primary: FilledButton(
      key: const Key('mobile_onboarding_finish'),
      onPressed: finishing ? null : () async => onFinish(),
      style: buttonStyle,
      child: const Text('Take me to Omi'),
    ),
    secondary: error == null
        ? null
        : Semantics(
            liveRegion: true,
            child: Text(
              error!,
              style: const TextStyle(color: Color(0xffffb4ab)),
            ),
          ),
  );
}
