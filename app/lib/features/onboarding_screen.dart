import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../capabilities/desktop_capabilities.dart';
import '../native/native_hub.dart';
import '../onboarding/onboarding_controller.dart';
import 'onboarding/backdrop.dart';
import 'onboarding/permission_gate.dart';
import 'omi_shell.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    required this.services,
    required this.onFinish,
    this.capabilities,
    super.key,
  });

  final AppServices services;
  final DesktopCapabilityGateway? capabilities;
  final FutureOr<void> Function() onFinish;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final onboarding = OnboardingController();
  StreamSubscription<NativeEvent>? scanEvents;
  List<OnboardingScanSource>? scanSources;
  String? scanSummary;
  String? scanRequestId;
  String? scanError;
  bool scanStarting = false;
  bool previewing = false;
  bool finishing = false;
  String? finishError;

  @override
  void initState() {
    super.initState();
    onboarding.addListener(_refresh);
    widget.services.auth.addListener(_refresh);
    scanEvents = widget.services.nativeEvents.listen(_handleNativeEvent);
  }

  @override
  void dispose() {
    unawaited(scanEvents?.cancel());
    onboarding.removeListener(_refresh);
    widget.services.auth.removeListener(_refresh);
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
    setState(() {
      scanStarting = true;
      scanError = null;
    });
    try {
      final requestId = await widget.services.scanOnboardingSources();
      if (!mounted) return;
      setState(() {
        scanRequestId = requestId;
        scanStarting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        scanStarting = false;
        scanError = 'I couldn’t start the private scan. Try again.';
      });
    }
  }

  void _handleNativeEvent(NativeEvent event) {
    if (event case NativeEventOnboardingScanCompleted(:final value)) {
      if (!mounted ||
          onboarding.stage != OnboardingStage.scan ||
          (scanRequestId != null && value.requestId != scanRequestId)) {
        return;
      }
      setState(() {
        scanRequestId = value.requestId;
        scanSources = value.sources;
        scanSummary = value.summary;
        scanError = null;
      });
    }
  }

  void _retryScan() {
    setState(() {
      scanRequestId = null;
      scanSources = null;
      scanSummary = null;
      scanError = null;
    });
    unawaited(_startScan());
  }

  void _openPreview() {
    setState(() => previewing = true);
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
        child: SafeArea(
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
                      key: ValueKey('scan'),
                      sources: scanSources,
                      summary: scanSummary,
                      error: scanError,
                      onRetry: _retryScan,
                      onContinue: onboarding.completeScan,
                    ),
                    OnboardingStage.profile => _ProfileNotice(
                      key: const ValueKey('profile'),
                      notice: scanSummary,
                      onContinue: onboarding.completeProfile,
                    ),
                    OnboardingStage.use => _UseStep(
                      key: const ValueKey('use'),
                      finishing: finishing,
                      error: finishError,
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

class _Introduction extends StatelessWidget {
  const _Introduction({required this.onContinue, super.key});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const _RandomizedText(
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
          fontFamily: 'Avenir Next',
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
      FilledButton(
        key: const Key('continue_preview_intro'),
        onPressed: onContinue,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 56),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          backgroundColor: const Color(0xfffffcec),
          foregroundColor: const Color(0xff171716),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontFamily: 'Avenir Next',
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        child: const Text('Hi Omi!'),
      ),
    ],
  );
}

class _ProfileNotice extends StatelessWidget {
  const _ProfileNotice({
    required this.notice,
    required this.onContinue,
    super.key,
  });

  final String? notice;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      _RandomizedText(
        key: ValueKey(notice ?? 'noticing'),
        segments: [(notice ?? 'Here’s what I noticed.', null)],
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xfffffcec),
          fontFamily: 'Avenir Next',
          fontSize: 32,
          fontWeight: FontWeight.w500,
          height: 1.35,
          letterSpacing: -.6,
        ),
      ),
      const SizedBox(height: 36),
      FilledButton(
        key: const Key('keep_profile'),
        onPressed: onContinue,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 56),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          backgroundColor: const Color(0xfffffcec),
          foregroundColor: const Color(0xff171716),
          shape: const StadiumBorder(),
        ),
        child: const Text('Continue'),
      ),
    ],
  );
}

class _ScanStep extends StatelessWidget {
  const _ScanStep({
    required this.sources,
    required this.summary,
    required this.error,
    required this.onRetry,
    required this.onContinue,
    super.key,
  });

  final List<OnboardingScanSource>? sources;
  final String? summary;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        liveRegion: true,
        child: _RandomizedText(
          key: ValueKey(
            sources == null && error == null
                ? 'Give me a second…'
                : 'Here’s what I could read.',
          ),
          segments: [
            (
              sources == null && error == null
                  ? 'Give me a second…'
                  : 'Here’s what I could read.',
              null,
            ),
          ],
          style:
              Theme.of(context).textTheme.displaySmall?.copyWith(
                color: const Color(0xfffffcec),
                fontSize: 44,
                letterSpacing: -1.6,
              ) ??
              const TextStyle(color: Color(0xfffffcec), fontSize: 44),
        ),
      ),
      const SizedBox(height: 24),
      if (summary case final value?) ...[
        _RandomizedText(
          key: ValueKey(value),
          segments: [(value, null)],
          style: const TextStyle(
            color: Color(0xfffffcec),
            fontSize: 20,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 18),
      ],
      if (sources case final results?)
        for (final source in results)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  source.state == OnboardingScanState.complete
                      ? Icons.check_rounded
                      : Icons.info_outline_rounded,
                  color: const Color(0xfffffcec),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _sourceName(source.source),
                        style: const TextStyle(
                          color: Color(0xfffffcec),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        source.detail,
                        style: const TextStyle(color: Color(0xffd0cec6)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      if (error case final message?)
        Text(message, style: const TextStyle(color: Color(0xffffb4ab))),
      const SizedBox(height: 24),
      if (sources != null)
        FilledButton(onPressed: onContinue, child: const Text('Continue'))
      else if (error != null)
        OutlinedButton(onPressed: onRetry, child: const Text('Try again'))
      else
        const LinearProgressIndicator(),
    ],
  );

  static String _sourceName(String source) => switch (source) {
    'workspace' => 'Workspace',
    'apple_notes' => 'Apple Notes',
    'apple_mail' => 'Apple Mail',
    _ => source,
  };
}

class _UseStep extends StatelessWidget {
  const _UseStep({
    required this.finishing,
    required this.error,
    required this.onFinish,
    super.key,
  });

  final bool finishing;
  final String? error;
  final FutureOr<void> Function() onFinish;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Omi is always within reach.',
        style: Theme.of(context).textTheme.displaySmall?.copyWith(
          color: const Color(0xfffffcec),
          fontSize: 44,
          letterSpacing: -1.6,
        ),
      ),
      const SizedBox(height: 18),
      const Text(
        'Tap both Shift keys to open Omi. Hold them to talk, then let go when you’re finished. Try asking: “What tasks do I have today?”',
        style: TextStyle(color: Color(0xffd0cec6), fontSize: 18, height: 1.5),
      ),
      const SizedBox(height: 32),
      FilledButton(
        key: const Key('finish_voice_lesson'),
        onPressed: finishing ? null : () async => onFinish(),
        child: const Text('Take me to Omi'),
      ),
      if (error case final message?) ...[
        const SizedBox(height: 12),
        Semantics(
          liveRegion: true,
          child: Text(
            message,
            style: const TextStyle(color: Color(0xffffb4ab)),
          ),
        ),
      ],
    ],
  );
}

class _RandomizedText extends StatefulWidget {
  const _RandomizedText({
    required this.segments,
    required this.style,
    this.textAlign = TextAlign.start,
    super.key,
  });

  final List<(String, TextStyle?)> segments;
  final TextStyle style;
  final TextAlign textAlign;

  @override
  State<_RandomizedText> createState() => _RandomizedTextState();
}

class _RandomizedTextState extends State<_RandomizedText>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late final tokens = _tokens();

  List<({String text, TextStyle? style, double delay})> _tokens() {
    final random = math.Random();
    return [
      for (final segment in widget.segments)
        for (final match in RegExp(r'\s+|\S+').allMatches(segment.$1))
          (
            text: match.group(0)!,
            style: segment.$2,
            delay: match.group(0)!.trim().isEmpty
                ? 0
                : .05 + random.nextDouble() * .18,
          ),
    ];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      animation.value = 1;
    } else if (!animation.isAnimating && animation.value == 0) {
      animation.forward();
    }
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.segments.map((segment) => segment.$1).join(),
    child: ExcludeSemantics(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) => Text.rich(
          TextSpan(
            children: [
              for (final token in tokens)
                TextSpan(
                  text: token.text,
                  style: _style(token.style, token.delay),
                ),
            ],
          ),
          style: widget.style,
          textAlign: widget.textAlign,
        ),
      ),
    ),
  );

  TextStyle _style(TextStyle? tokenStyle, double delay) {
    final progress = ((animation.value - delay) / .62).clamp(0.0, 1.0);
    final opacity = Curves.easeOutExpo.transform(progress);
    final style = widget.style.merge(tokenStyle);
    final color = style.color ?? const Color(0xffffffff);
    return style.copyWith(color: color.withValues(alpha: color.a * opacity));
  }
}
