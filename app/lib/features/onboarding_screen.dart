import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../keyboard/keyboard.dart';
import '../keyboard/shake_gesture.dart';
import '../keyboard/voice_transcripts.dart';
import '../capabilities/desktop_capabilities.dart';
import '../native/native_hub.dart';
import '../onboarding/hub_checklist.dart';
import '../onboarding/onboarding_controller.dart';
import '../onboarding/starter_tasks.dart';
import '../ui/omi_ui.dart';
import 'cursor_pill_controller.dart';
import 'cursor_pill_window.dart';
import 'onboarding/backdrop.dart';
import 'onboarding/byok_step.dart';
import 'onboarding/permission_gate.dart';
import 'onboarding/randomized_text.dart';
import 'omi_shell.dart';
import 'voice_intents.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    required this.services,
    required this.onFinish,
    this.capabilities,
    this.checklistStore,
    this.starterTaskTimeout = const Duration(seconds: 8),
    super.key,
  });

  final AppServices services;
  final DesktopCapabilityGateway? capabilities;
  final FutureOr<void> Function() onFinish;

  /// Where locally derived starter tasks are seeded so the hub can show
  /// them; the hub reads the same store.
  final HubChecklistStore? checklistStore;

  /// How long to wait for the signed-in currents generate cycle before
  /// continuing anyway.
  final Duration starterTaskTimeout;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final onboarding = OnboardingController();
  StreamSubscription<NativeEvent>? scanEvents;
  List<OnboardingScanSource>? scanSources;
  String? scanSummary;
  String? scanDetectedName;
  List<String> scanDetectedLanguages = const [];
  String? scanRequestId;
  String? scanError;
  bool scanStarting = false;
  // Monotonic generation, bumped on every scan start (initial and each
  // retry). Used to make the async continuation of _startScan a no-op once
  // a newer attempt has superseded it, independent of scanRequestId's
  // nullability.
  int _scanGeneration = 0;
  bool previewing = false;
  bool preparingTasks = false;
  bool finishing = false;
  String? finishError;
  CursorPillController? _pillController;

  // Shake finale (use step): after the voice lesson the user is asked to
  // press Esc and shake the cursor. The shake fills a glow that then bursts
  // to the screen edges before onboarding completes into the hub.
  bool _useVoiceDone = false;
  double _useShakeProgress = 0;
  bool _useShakeComplete = false;
  double? _lastUseShakeX;
  int _lastUseShakeDirection = 0;
  DateTime _lastUseShakeReversalAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _useShakeDecayTimer;

  CursorPillController get _usePillController {
    final existing = _pillController;
    if (existing != null) return existing;
    widget.services.desktopVoiceIntentInterceptor = (_) => true;
    final controller = CursorPillController(
      hub: widget.services.nativeHub,
      events: widget.services.nativeEvents,
      startVoice: widget.services.startDesktopVoice,
      stopVoice: () async =>
          (await widget.services.stopDesktopVoice())?.text ?? '',
      cancelVoice: widget.services.cancelDesktopVoice,
      sendPrompt: (_) async => null,
      level: CombinedVoiceLevel([
        widget.services.desktopVoice.level,
        widget.services.liveVoice.level,
      ]),
      // The lesson drives the same native surfaces the real gesture does —
      // a static pill panel at the cursor and a full-screen glow — so what
      // is taught is exactly what ships, not an in-window imitation clipped
      // to the onboarding frame.
      presentWindow: (centered) =>
          centered ? CursorPillWindow.summon() : VoiceOverlayWindow.start(),
      dismissWindow: () async {
        await CursorPillWindow.restore();
        await VoiceOverlayWindow.stop();
      },
      voiceLevelSink: VoiceOverlayWindow.level,
    );
    controller.addListener(_refresh);
    _pillController = controller;
    return controller;
  }

  // The pill and the glow are native windows owned by the platform side, so
  // the lesson only tracks the pointer for the shake meter — there is nothing
  // left to draw in-window.
  Widget _withCursorPillOverlay(Widget base) {
    final shakeActive =
        onboarding.stage == OnboardingStage.use && _useVoiceDone;
    return MouseRegion(
      opaque: false,
      onHover: (event) {
        if (shakeActive && !_useShakeComplete) _trackUseShake(event.position);
      },
      child: base,
    );
  }

  @override
  void initState() {
    super.initState();
    onboarding.addListener(_refresh);
    widget.services.auth.addListener(_refresh);
    scanEvents = widget.services.nativeEvents.listen(_handleNativeEvent);
  }

  @override
  void dispose() {
    _useShakeDecayTimer?.cancel();
    unawaited(scanEvents?.cancel());
    onboarding.removeListener(_refresh);
    widget.services.auth.removeListener(_refresh);
    widget.services.desktopVoiceIntentInterceptor = null;
    _pillController?.dispose();
    onboarding.dispose();
    super.dispose();
  }

  void _refresh() {
    if (onboarding.stage == OnboardingStage.scan &&
        scanRequestId == null &&
        !scanStarting &&
        scanSources == null) {
      unawaited(_startScan());
    }
    setState(() {});
  }

  Future<void> _startScan() async {
    final generation = ++_scanGeneration;
    setState(() {
      scanStarting = true;
      scanError = null;
    });
    try {
      final requestId = await widget.services.scanOnboardingSources();
      if (!mounted || generation != _scanGeneration) return;
      setState(() {
        scanRequestId = requestId;
        scanStarting = false;
      });
    } catch (_) {
      if (!mounted || generation != _scanGeneration) return;
      setState(() {
        scanStarting = false;
        scanError = 'I couldn’t start the private scan. Try again.';
      });
    }
  }

  void _handleNativeEvent(NativeEvent event) {
    if (event case NativeEventOnboardingScanCompleted(:final value)) {
      // Reject any event whose requestId doesn't match the one we're
      // currently expecting — including while scanRequestId is null (a scan
      // is starting or was just retried). Relying on nullability here let a
      // stale scan's completion slip through while a retry was in flight.
      if (!mounted ||
          onboarding.stage != OnboardingStage.scan ||
          value.requestId != scanRequestId) {
        return;
      }
      setState(() {
        scanRequestId = value.requestId;
        scanSources = value.sources;
        scanSummary = _sanitizeScanSummary(value.summary);
        scanDetectedName = value.detectedName;
        scanDetectedLanguages = value.detectedLanguages;
        scanError = null;
      });
      // The scan stage is a pure waiting state ("Learning about you…"); the
      // results themselves are presented on the profile step, so advance as
      // soon as the scan lands rather than showing an intermediate slide.
      onboarding.completeScan();
    }
  }

  void _useReturningUserFlow() {
    // Eagerly trigger a full resync of the existing account's memory/profile
    // (instead of lazily on the next auth change), since a returning user
    // skips the fresh on-device scan entirely and needs their existing data
    // pulled from the backend as soon as this flow starts.
    unawaited(widget.services.resyncAccount().onError((_, _) {}));
    onboarding.beginReturningUserFlow();
  }

  void _retryScan() {
    // Bump the generation immediately (synchronously) so any in-flight
    // completion for the superseded scan is ignored by _startScan's own
    // continuation, even before the new scan's requestId is known.
    _scanGeneration += 1;
    setState(() {
      scanRequestId = null;
      scanSources = null;
      scanSummary = null;
      scanDetectedName = null;
      scanDetectedLanguages = const [];
      scanError = null;
    });
    unawaited(_startScan());
  }

  void _openPreview() {
    setState(() => previewing = true);
  }

  void _onVoiceLessonComplete() {
    if (_useVoiceDone) return;
    setState(() => _useVoiceDone = true);
    _useShakeDecayTimer ??= Timer.periodic(const Duration(milliseconds: 120), (
      _,
    ) {
      if (!mounted || _useShakeComplete || _useShakeProgress <= 0) return;
      setState(() => _useShakeProgress = (_useShakeProgress - 8).clamp(0, 100));
    });
  }

  void _trackUseShake(Offset position) {
    final now = DateTime.now();
    final lastX = _lastUseShakeX;
    _lastUseShakeX = position.dx;
    if (lastX == null) return;
    final movement = position.dx - lastX;
    if (movement.abs() < 7) return;
    final direction = movement.isNegative ? -1 : 1;
    final elapsedMs = now.difference(_lastUseShakeReversalAt).inMilliseconds;
    if (isShakeReversal(
      _lastUseShakeDirection,
      direction,
      elapsedMs,
      movement,
    )) {
      final progress = advanceShakeProgress(_useShakeProgress, movement);
      if (_useShakeProgress <= 0 && progress > 0) {
        unawaited(VoiceOverlayWindow.startGlow());
      }
      setState(() => _useShakeProgress = progress);
      unawaited(VoiceOverlayWindow.level(progress / 100));
      if (progress >= 100 && !_useShakeComplete) {
        setState(() => _useShakeComplete = true);
        unawaited(VoiceOverlayWindow.burst().then((_) => _finish()));
      }
      _lastUseShakeReversalAt = now;
    } else if (direction != _lastUseShakeDirection) {
      _lastUseShakeReversalAt = now;
    }
    _lastUseShakeDirection = direction;
  }

  Future<void> _finish() async {
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
        finishError = 'I couldn’t save your setup. Try again.';
      });
    }
  }

  String get _defaultProfileName {
    final detected = scanDetectedName?.trim();
    if (detected != null && detected.isNotEmpty) return detected;
    final displayName = widget.services.auth.snapshot.session?.displayName
        ?.trim();
    return (displayName == null || displayName.isEmpty) ? 'there' : displayName;
  }

  List<String> get _defaultProfileLanguages =>
      {...scanDetectedLanguages, ..._deviceLanguageNames()}.toList();

  Future<void> _completeProfile(String name, List<String> languages) async {
    if (preparingTasks) return;
    final trimmed = name.trim();
    unawaited(
      widget.services
          .captureOnboardingProfile(
            name: trimmed.isEmpty || trimmed == 'there' ? null : trimmed,
            languages: languages,
          )
          .onError((_, _) {}),
    );
    setState(() => preparingTasks = true);
    try {
      await _prepareStarterTasks();
    } catch (_) {}
    if (!mounted) return;
    setState(() => preparingTasks = false);
    onboarding.completeProfile();
  }

  /// Turns the scan results into the user's initial hub tasks before the
  /// profile step completes. Signed in, the profile capture already landed,
  /// so trigger a currents generate cycle and wait (bounded) for real cards;
  /// otherwise — or when the cycle produces nothing in time — derive 2–4
  /// starter tasks locally from the scan summary and evidence and seed the
  /// hub's local checklist store with them. Failures never block onboarding.
  Future<void> _prepareStarterTasks() async {
    final currents = widget.services.currents;
    if (currents != null && widget.services.canUseApi) {
      try {
        await currents.load().timeout(widget.starterTaskTimeout);
        if (currents.error == null && currents.items.isNotEmpty) return;
      } catch (_) {}
    }
    final derived = deriveStarterTasks(
      summary: scanSummary,
      sources: scanSources ?? const [],
    );
    if (derived.isEmpty) return;
    final store = widget.checklistStore ?? PreferencesHubChecklistStore();
    try {
      await store.setStarterTasks(derived);
      await store.setDoneStarterTasks(const []);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (previewing) {
      return OmiShell(
        services: widget.services,
        previewMode: true,
        onExitPreview: () => setState(() => previewing = false),
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: OnboardingBackdrop(
        bright: onboarding.stage.index >= OnboardingStage.scan.index,
        searching:
            onboarding.stage == OnboardingStage.scan &&
            scanSources == null &&
            scanError == null,
        settled:
            (onboarding.stage == OnboardingStage.scan && scanSources != null) ||
            onboarding.stage == OnboardingStage.profile,
        child: _withCursorPillOverlay(
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: onboarding.stage == OnboardingStage.access
                      ? 620
                      : 820,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 45,
                    vertical: 58,
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
                    child: switch (onboarding.stage) {
                      OnboardingStage.introduction => _Introduction(
                        key: const ValueKey('introduction'),
                        onContinue: onboarding.continueFromIntroduction,
                        onAlreadyHaveAccount: _useReturningUserFlow,
                      ),
                      OnboardingStage.access => ProductionGate(
                        key: const ValueKey('access'),
                        configurationMessage:
                            widget.services.configurationMessage,
                        auth: widget.services.auth,
                        capabilities:
                            widget.capabilities ?? widget.services.capabilities,
                        onOpenPreview: _openPreview,
                        onFinish: onboarding.completeAccess,
                      ),
                      OnboardingStage.scan => _ScanStep(
                        key: const ValueKey('scan'),
                        error: scanError,
                        onRetry: _retryScan,
                      ),
                      OnboardingStage.profile => OnboardingProfileStep(
                        key: const ValueKey('profile'),
                        notice: scanSummary,
                        defaultName: _defaultProfileName,
                        defaultLanguages: _defaultProfileLanguages,
                        preparing: preparingTasks,
                        onContinue: (name, languages) =>
                            unawaited(_completeProfile(name, languages)),
                      ),
                      // Bringing your own provider is offered once, right
                      // after the profile: the negotiated price only applies
                      // to a key that is actually connected.
                      OnboardingStage.byok => OnboardingByokStep(
                        key: const ValueKey('byok'),
                        client: widget.services.byok,
                        onConnect: widget.services.saveProviderCredential,
                        onFinish: onboarding.completeByok,
                      ),
                      OnboardingStage.use => OnboardingUseStep(
                        key: const ValueKey('use'),
                        pill: _usePillController,
                        transcripts: finalVoiceTranscripts(
                          widget.services.nativeEvents,
                        ),
                        finishing: finishing,
                        error: finishError,
                        finale: _useVoiceDone,
                        shakeProgress: _useShakeProgress,
                        shakeComplete: _useShakeComplete,
                        onVoiceLessonComplete: _onVoiceLessonComplete,
                        onFinish: _finish,
                      ),
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Introduction extends StatelessWidget {
  const _Introduction({
    required this.onContinue,
    required this.onAlreadyHaveAccount,
    super.key,
  });

  final VoidCallback onContinue;
  final VoidCallback onAlreadyHaveAccount;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      const RandomizedText(
        segments: [
          ('Hi, I’m Omi. I’m a ', null),
          ('second brain', TextStyle(fontWeight: FontWeight.w700)),
          (' you can ', null),
          ('actually trust', TextStyle(fontStyle: FontStyle.italic)),
          ('—built to ', null),
          ('surface what’s important', TextStyle(fontWeight: FontWeight.w700)),
          (' in your life and help you ', null),
          ('get things done.', TextStyle(fontWeight: FontWeight.w700)),
        ],
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Color(0xfffffcec),
          fontFamily: OmiFonts.sans,
          fontSize: 46,
          fontWeight: FontWeight.w500,
          height: 1.08,
          letterSpacing: -2.07,
          shadows: [
            Shadow(
              color: Color(0x80000000),
              blurRadius: 18,
              offset: Offset(0, 1),
            ),
          ],
        ),
      ),
      const SizedBox(height: 40),
      Center(
        child: OmiButton(
          key: const Key('continue_preview_intro'),
          onPressed: onContinue,
          child: const Text('Hi Omi!'),
        ),
      ),
      const SizedBox(height: 10),
      Center(
        child: TextButton(
          key: const Key('already_have_account'),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xb3fffcec),
            textStyle: const TextStyle(
              fontFamily: OmiFonts.sans,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          onPressed: onAlreadyHaveAccount,
          child: const Text('Already have an account?'),
        ),
      ),
    ],
  );
}

const _profileLanguageNames = {
  'en': 'English',
  'es': 'Spanish',
  'fr': 'French',
  'de': 'German',
  'ja': 'Japanese',
  'zh': 'Mandarin',
};

List<String> _deviceLanguageNames() {
  final names = <String>{
    for (final locale in WidgetsBinding.instance.platformDispatcher.locales)
      ?_profileLanguageNames[locale.languageCode],
  };
  return names.isEmpty ? ['English'] : names.toList();
}

String? _sanitizeScanSummary(String? summary) {
  if (summary == null) return null;
  final cleaned = summary.replaceAll(RegExp(r'\s+'), ' ').trim();
  return cleaned.isEmpty ? null : cleaned;
}

const scanSummaryEmphasisStyle = TextStyle(
  color: Color(0xfffffcec),
  fontWeight: FontWeight.w600,
);
const scanSummaryDimmedStyle = TextStyle(color: Color(0x80fffcec));

String _stripScanSummaryMarkdown(String value) => value
    .replaceAll('*', '')
    .replaceAll('`', '')
    .replaceAll('#', '')
    .replaceAllMapped(RegExp(r'_+([^_]*)_+'), (match) => match.group(1) ?? '');

@visibleForTesting
List<(String, TextStyle?)> parseScanSummarySegments(String summary) {
  final parts = summary.split('**');
  if (parts.length < 3) {
    final whole = _stripScanSummaryMarkdown(
      summary,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    return whole.isEmpty ? const [] : [(whole, null)];
  }
  final balanced = parts.length.isOdd;
  final segments = <(String, TextStyle?)>[];
  for (var index = 0; index < parts.length; index++) {
    final text = _stripScanSummaryMarkdown(parts[index]);
    if (text.isEmpty) continue;
    final emphasized = index.isOdd && (balanced || index < parts.length - 1);
    segments.add((
      text,
      emphasized ? scanSummaryEmphasisStyle : scanSummaryDimmedStyle,
    ));
  }
  return segments;
}

class OnboardingProfileStep extends StatefulWidget {
  const OnboardingProfileStep({
    required this.notice,
    required this.defaultName,
    required this.defaultLanguages,
    required this.onContinue,
    this.preparing = false,
    super.key,
  });

  final String? notice;
  final String defaultName;
  final List<String> defaultLanguages;
  final bool preparing;
  final void Function(String name, List<String> languages) onContinue;

  @override
  State<OnboardingProfileStep> createState() => _OnboardingProfileStepState();
}

class _OnboardingProfileStepState extends State<OnboardingProfileStep> {
  static const _cream = Color(0xfffffcec);
  static const _ink = Color(0xff171716);

  late String name = widget.defaultName;
  late final List<String> languages = List.of(widget.defaultLanguages);
  late final nameController = TextEditingController(text: widget.defaultName);
  bool editingName = false;
  bool pickingLanguages = false;

  List<String> get _languageOptions => [
    ...widget.defaultLanguages,
    for (final option in _profileLanguageNames.values)
      if (!widget.defaultLanguages.contains(option)) option,
  ];

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  void _commitName() {
    final value = nameController.text.trim();
    setState(() {
      editingName = false;
      if (value.isNotEmpty) name = value;
      nameController.text = name;
    });
  }

  Widget _chip({
    required Key key,
    required String label,
    required VoidCallback onTap,
  }) => Material(
    key: key,
    color: _cream,
    shape: const StadiumBorder(),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: _ink,
                fontFamily: OmiFonts.sans,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.edit_rounded, size: 15, color: _ink),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    const prose = TextStyle(
      color: _cream,
      fontFamily: OmiFonts.sans,
      fontSize: 24,
      fontWeight: FontWeight.w500,
      height: 1.5,
      letterSpacing: -.4,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const RandomizedText(
          segments: [('Here’s what I noticed.', null)],
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _cream,
            fontFamily: OmiFonts.sans,
            fontSize: 38,
            fontWeight: FontWeight.w500,
            height: 1.2,
            letterSpacing: -1.2,
          ),
        ),
        const SizedBox(height: 28),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 10,
          children: [
            const Text('You are ', style: prose),
            if (editingName)
              SizedBox(
                width: 200,
                child: TextField(
                  key: const Key('profile_name_field'),
                  controller: nameController,
                  autofocus: true,
                  style: const TextStyle(
                    color: _cream,
                    fontFamily: OmiFonts.sans,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: const InputDecoration(isDense: true),
                  onSubmitted: (_) => _commitName(),
                  onTapOutside: (_) => _commitName(),
                ),
              )
            else
              _chip(
                key: const Key('profile_name_chip'),
                label: name,
                onTap: () => setState(() => editingName = true),
              ),
            const Text('. You speak ', style: prose),
            _chip(
              key: const Key('profile_languages_chip'),
              label: languages.join(', '),
              onTap: () => setState(() => pickingLanguages = !pickingLanguages),
            ),
            const Text('.', style: prose),
          ],
        ),
        if (pickingLanguages) ...[
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in _languageOptions)
                FilterChip(
                  key: Key('profile_language_$option'),
                  label: Text(option),
                  selected: languages.contains(option),
                  showCheckmark: true,
                  selectedColor: _cream,
                  checkmarkColor: _ink,
                  labelStyle: TextStyle(
                    color: languages.contains(option) ? _ink : _cream,
                    fontWeight: FontWeight.w600,
                  ),
                  side: const BorderSide(color: Color(0x59fffcec)),
                  backgroundColor: Colors.transparent,
                  onSelected: (selected) => setState(() {
                    if (selected) {
                      languages.add(option);
                    } else if (languages.length > 1) {
                      languages.remove(option);
                    }
                  }),
                ),
            ],
          ),
        ],
        if (widget.notice case final value?) ...[
          const SizedBox(height: 26),
          RandomizedText(
            key: ValueKey(value),
            segments: parseScanSummarySegments(value),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _cream,
              fontFamily: OmiFonts.sans,
              fontSize: 20,
              fontWeight: FontWeight.w500,
              height: 1.5,
            ),
          ),
        ],
        const SizedBox(height: 36),
        if (widget.preparing)
          Semantics(
            liveRegion: true,
            child: Row(
              key: const Key('preparing_tasks'),
              mainAxisSize: MainAxisSize.min,
              children: const [
                OmiActivityOrb.loading(size: 22, color: _cream),
                SizedBox(width: 12),
                Text(
                  'Preparing your tasks…',
                  style: TextStyle(
                    color: _cream,
                    fontFamily: OmiFonts.sans,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          )
        else
          OmiButton(
            key: const Key('keep_profile'),
            onPressed: () => widget.onContinue(name, List.of(languages)),
            child: const Text('Continue'),
          ),
      ],
    );
  }
}

class _ScanStep extends StatelessWidget {
  const _ScanStep({required this.error, required this.onRetry, super.key});

  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Semantics(
        liveRegion: true,
        child: RandomizedText(
          key: ValueKey(error == null ? 'learning' : 'scan_error'),
          segments: [(error == null ? 'Learning about you…' : error!, null)],
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xfffffcec),
            fontFamily: OmiFonts.sans,
            fontSize: 38,
            fontWeight: FontWeight.w500,
            height: 1.2,
            letterSpacing: -1.2,
            shadows: [
              Shadow(
                color: Color(0x80000000),
                blurRadius: 18,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
      ),
      if (error != null) ...[
        const SizedBox(height: 28),
        Center(
          child: OmiButton(
            variant: OmiButtonVariant.secondary,
            onPressed: onRetry,
            child: const Text('Try again'),
          ),
        ),
      ],
    ],
  );
}

class OnboardingUseStep extends StatefulWidget {
  const OnboardingUseStep({
    required this.pill,
    required this.transcripts,
    required this.finishing,
    required this.error,
    required this.finale,
    required this.shakeProgress,
    required this.shakeComplete,
    required this.onVoiceLessonComplete,
    required this.onFinish,
    super.key,
  });

  final CursorPillController pill;
  final Stream<String> transcripts;
  final bool finishing;
  final String? error;

  /// True once the voice lesson is satisfied and the step is in its shake
  /// finale (the parent screen owns the shake tracking + glow burst).
  final bool finale;
  final double shakeProgress;
  final bool shakeComplete;
  final VoidCallback onVoiceLessonComplete;
  final FutureOr<void> Function() onFinish;

  @override
  State<OnboardingUseStep> createState() => _OnboardingUseStepState();
}

class _OnboardingUseStepState extends State<OnboardingUseStep> {
  bool leftShiftDown = false;
  bool rightShiftDown = false;
  bool _lessonSignalled = false;
  bool _typeLessonDone = false;
  CursorPillState lastPillState = CursorPillState.hidden;
  StreamSubscription<String>? transcriptEvents;

  /// The same chord state machine the shell uses, so the lesson teaches the
  /// real timing: one chord summons typing, two chords inside the window
  /// start voice.
  final _chords = ShiftGestureMachine();
  Timer? _chordTimer;

  void _signalVoiceLesson() {
    if (_lessonSignalled) return;
    _lessonSignalled = true;
    widget.onVoiceLessonComplete();
  }

  @override
  void initState() {
    super.initState();
    lastPillState = widget.pill.state;
    HardwareKeyboard.instance.addHandler(_handleKey);
    widget.pill.addListener(_pillChanged);
    transcriptEvents = widget.transcripts.listen(_handleTranscript);
  }

  @override
  void dispose() {
    _chordTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleKey);
    widget.pill.removeListener(_pillChanged);
    unawaited(transcriptEvents?.cancel());
    super.dispose();
  }

  /// A double-shift (or Esc) while listening stops voice and hides the pill.
  /// Performing that stop IS the voice lesson completing — the user talked
  /// and stopped — so hand off to the shake finale rather than finishing
  /// outright, even when speech recognition produced no transcript (the live
  /// route can drain late or be unavailable in offline setups). Dismissing
  /// the typing bar the same way completes the earlier type lesson.
  void _pillChanged() {
    if (!mounted) return;
    final state = widget.pill.state;
    final wasListening = lastPillState == CursorPillState.listening;
    final wasTyping = lastPillState == CursorPillState.input;
    lastPillState = state;
    if (wasTyping && state == CursorPillState.hidden) {
      _typeLessonDone = true;
    }
    if (wasListening && state == CursorPillState.hidden && !widget.finale) {
      _typeLessonDone = true;
      _signalVoiceLesson();
    }
    setState(() {});
  }

  void _routeChordActions(List<ShiftGestureAction> actions) {
    for (final action in actions) {
      unawaited(widget.pill.handleGesture(action));
    }
    _chordTimer?.cancel();
    _chordTimer = null;
    if (!_chords.hasPendingChord) return;
    _chordTimer = Timer(_chords.doubleChordWindow, () {
      if (!mounted) return;
      _routeChordActions(_chords.chordTimeout());
    });
  }

  bool _handleKey(KeyEvent event) {
    final physical = event.physicalKey;
    if (physical == PhysicalKeyboardKey.escape && event is KeyDownEvent) {
      unawaited(widget.pill.dismissSurface());
      return false;
    }
    if (widget.finale) return false;
    final isLeft = physical == PhysicalKeyboardKey.shiftLeft;
    final isRight = physical == PhysicalKeyboardKey.shiftRight;
    if (!isLeft && !isRight) return false;
    final down = event is KeyDownEvent;
    if (event is KeyRepeatEvent) return false;
    setState(() {
      if (isLeft) leftShiftDown = down;
      if (isRight) rightShiftDown = down;
    });
    _routeChordActions(
      _chords.shift(isLeft ? PhysicalShift.left : PhysicalShift.right, down),
    );
    return false;
  }

  void _handleTranscript(String text) {
    if (widget.finale) return;
    if (matchesShowHubIntent(text)) {
      unawaited(widget.pill.dismiss());
      _signalVoiceLesson();
      return;
    }
    // Final transcripts can land after the stop already hid the pill (the
    // provider drains asynchronously); a late transcript still satisfies the
    // voice lesson.
    if (widget.pill.state == CursorPillState.hidden) {
      _signalVoiceLesson();
    }
  }

  Widget _shiftKey({
    required Key key,
    required bool pressed,
    required bool listening,
    required bool shimmer,
  }) => KeycapShimmer(
    enabled: shimmer,
    child: AnimatedContainer(
      key: key,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      width: 132,
      height: 64,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: listening
            ? const Color(0xff2e8b57)
            : pressed
            ? const Color(0xfffffcec)
            : const Color(0x14fffcec),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: listening
              ? const Color(0xff2e8b57)
              : pressed
              ? const Color(0xfffffcec)
              : const Color(0x59fffcec),
          width: 1.5,
        ),
        boxShadow: listening
            ? const [BoxShadow(color: Color(0x662e8b57), blurRadius: 28)]
            : pressed
            ? const [BoxShadow(color: Color(0x66fffcec), blurRadius: 28)]
            : const [],
      ),
      child: Text(
        '⇧ shift',
        style: TextStyle(
          color: listening
              ? const Color(0xfffffcec)
              : pressed
              ? const Color(0xff171716)
              : const Color(0xb3fffcec),
          fontFamily: OmiFonts.sans,
          fontSize: 19,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );

  /// The keycaps start close together; once the type lesson is done and the
  /// user is asked to double-tap the chord, they slide apart while the ×2
  /// hint fades and scales in between them.
  Widget _timesTwoReveal({required bool shown}) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 350);
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOutCubic,
      width: shown ? 52 : 22,
      alignment: Alignment.center,
      child: AnimatedScale(
        scale: shown ? 1 : 0.6,
        duration: duration,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: shown ? 1 : 0,
          duration: duration,
          curve: Curves.easeOutCubic,
          child: shown
              ? const Text(
                  '×2',
                  key: Key('shift_times_two'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xb3fffcec),
                    fontFamily: OmiFonts.sans,
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  String get _prompt => switch (widget.pill.state) {
    CursorPillState.hidden when !_typeLessonDone =>
      'Press both Shift keys once to summon the typing bar. '
          '($summonOverlayKeybindLabel works anywhere too.)',
    CursorPillState.hidden => 'Now tap the chord twice to start talking to me.',
    CursorPillState.input =>
      'This is where you type. Press Esc — or the chord — to dismiss.',
    CursorPillState.working => 'Working on it…',
    CursorPillState.listening =>
      'Say something — then press Esc, or the chord, to stop.',
  };

  @override
  Widget build(BuildContext context) {
    if (widget.finale) return _shakeFinale(context);
    final listening = widget.pill.state == CursorPillState.listening;
    final expectingDoubleShift = !listening;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _shiftKey(
              key: const Key('shift_left'),
              pressed: leftShiftDown,
              listening: listening,
              shimmer: expectingDoubleShift,
            ),
            _timesTwoReveal(
              shown:
                  _typeLessonDone &&
                  widget.pill.state == CursorPillState.hidden,
            ),
            _shiftKey(
              key: const Key('shift_right'),
              pressed: rightShiftDown,
              listening: listening,
              shimmer: expectingDoubleShift,
            ),
          ],
        ),
        const SizedBox(height: 26),
        Opacity(
          opacity: .55,
          child: Semantics(
            liveRegion: true,
            child: Text(
              _prompt,
              key: const Key('use_step_prompt'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xb3fffcec),
                fontFamily: OmiFonts.sans,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        if (widget.error case final message?) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xffffb4ab)),
            ),
          ),
        ],
      ],
    );
  }

  /// The closing teaching beat: with voice learned, ask the user to press Esc
  /// and shake the cursor. The parent screen fills the glow and bursts it; on
  /// completion onboarding drops into the hub.
  Widget _shakeFinale(BuildContext context) => Column(
    key: const Key('use_shake_finale'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      const _CursorCue(),
      const SizedBox(height: 20),
      RandomizedText(
        segments: widget.shakeComplete
            ? const [('I’m listening.', null)]
            : const [('Press Esc — then shake your cursor.', null)],
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xfffffcec),
          fontFamily: OmiFonts.sans,
          fontSize: 34,
          fontWeight: FontWeight.w500,
          height: 1.15,
          letterSpacing: -1,
        ),
      ),
      const SizedBox(height: 16),
      Opacity(
        opacity: .55,
        child: Semantics(
          liveRegion: true,
          child: Text(
            widget.shakeComplete
                ? 'Shake anytime to reach me.'
                : '${widget.shakeProgress.round()}%',
            key: const Key('use_shake_prompt'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xb3fffcec),
              fontFamily: OmiFonts.sans,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
      if (widget.error case final message?) ...[
        const SizedBox(height: 12),
        Semantics(
          liveRegion: true,
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xffffb4ab)),
          ),
        ),
      ],
    ],
  );
}

/// The ↔ hint shown while the user is asked to shake the cursor. It used to
/// oscillate; the motion was distracting, so it is a static glyph now.
class _CursorCue extends StatelessWidget {
  const _CursorCue();

  @override
  Widget build(BuildContext context) =>
      const Text('↔', style: TextStyle(fontSize: 34, color: Color(0xff96c4ff)));
}

class KeycapShimmer extends StatefulWidget {
  const KeycapShimmer({required this.enabled, required this.child, super.key});

  static const period = Duration(milliseconds: 1800);

  final bool enabled;
  final Widget child;

  @override
  State<KeycapShimmer> createState() => _KeycapShimmerState();
}

class _KeycapShimmerState extends State<KeycapShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: KeycapShimmer.period,
  );

  bool get _active =>
      widget.enabled && !MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant KeycapShimmer old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (_active) {
      if (!_sweep.isAnimating) _sweep.repeat();
    } else {
      _sweep.stop();
      _sweep.value = 0;
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return widget.child;
    return AnimatedBuilder(
      animation: _sweep,
      child: widget.child,
      builder: (context, child) {
        final travel = -1.6 + 3.2 * _sweep.value;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment(travel - 0.7, travel - 0.7),
            end: Alignment(travel + 0.7, travel + 0.7),
            colors: const [
              Color(0x00ffffff),
              Color(0x4dfffcec),
              Color(0x00ffffff),
            ],
          ).createShader(bounds),
          child: child,
        );
      },
    );
  }
}
