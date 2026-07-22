import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../auth/auth.dart';
import '../capabilities/desktop_capabilities.dart';
import '../native/native_hub.dart';
import '../onboarding/onboarding_controller.dart';
import 'omi_shell.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    required this.services,
    this.capabilities,
    this.onFinish,
    super.key,
  });

  final AppServices services;
  final DesktopCapabilityGateway? capabilities;
  final FutureOr<void> Function()? onFinish;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final answerController = TextEditingController();
  final onboarding = OnboardingController();
  StreamSubscription<NativeEvent>? scanEvents;
  List<OnboardingScanSource>? scanSources;
  String? scanRequestId;
  String? scanError;
  bool scanStarting = false;

  static const prompts = [
    (
      'Here’s what I noticed.',
      'What should Omi call you, and what are you focused on right now?',
      'I’m Alex. I’m building a product and want help staying focused.',
    ),
    (
      'Shape your thinking partner.',
      'What would you want Omi to notice, remember, or help with?',
      'Remember decisions, surface loose ends, and protect my focus.',
    ),
  ];

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
    answerController.dispose();
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
    } catch (error) {
      if (!mounted) return;
      setState(() {
        scanStarting = false;
        scanError = error.toString();
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
        scanError = null;
      });
    }
  }

  void _retryScan() {
    setState(() {
      scanRequestId = null;
      scanSources = null;
      scanError = null;
    });
    unawaited(_startScan());
  }

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

  Future<void> _finish() async {
    if (widget.onFinish case final onFinish?) {
      await onFinish();
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => OmiShell(services: widget.services),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _OnboardingBackdrop(
        bright: onboarding.stage.index >= OnboardingStage.scan.index,
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
                  duration: const Duration(milliseconds: 350),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, .025),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
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
                      error: scanError,
                      onRetry: _retryScan,
                      onContinue: onboarding.completeScan,
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
                    OnboardingStage.use => _UseStep(
                      key: const ValueKey('use'),
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
      Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'Hi, I’m Omi. I’m a '),
            const TextSpan(
              text: 'second brain',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const TextSpan(text: ' you can '),
            const TextSpan(
              text: 'actually trust',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
            const TextSpan(text: '—built to '),
            const TextSpan(
              text: 'surface what’s important',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const TextSpan(text: ' in your life and help you '),
            const TextSpan(
              text: 'get things done.',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        textAlign: TextAlign.center,
        style: const TextStyle(
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'PROFILE ${index + 1} OF $count',
        style: const TextStyle(
          color: Color(0xffd0cec6),
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
  );
}

class _ScanStep extends StatelessWidget {
  const _ScanStep({
    required this.sources,
    required this.error,
    required this.onRetry,
    required this.onContinue,
    super.key,
  });

  final List<OnboardingScanSource>? sources;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        liveRegion: true,
        child: Text(
          sources == null && error == null
              ? 'Give me a second…'
              : 'Here’s what I could read.',
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
            color: const Color(0xfffffcec),
            fontSize: 44,
            letterSpacing: -1.6,
          ),
        ),
      ),
      const SizedBox(height: 24),
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
  const _UseStep({required this.onFinish, super.key});

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
        onPressed: () async => onFinish(),
        child: const Text('Take me to Omi'),
      ),
    ],
  );
}

class _OnboardingBackdrop extends StatelessWidget {
  const _OnboardingBackdrop({required this.child, required this.bright});

  final Widget child;
  final bool bright;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS)
        const ColoredBox(color: Color(0xff9ba0a3)),
      AnimatedOpacity(
        duration: const Duration(milliseconds: 2500),
        curve: Curves.easeOutQuart,
        opacity: bright ? .7 : 0,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 2500),
          curve: Curves.easeOutQuart,
          offset: bright ? Offset.zero : const Offset(0, .34),
          child: AnimatedScale(
            duration: const Duration(milliseconds: 2500),
            curve: Curves.easeOutQuart,
            scale: bright ? 1 : 1.12,
            child: const _OnboardingEdgeGradient(),
          ),
        ),
      ),
      child,
    ],
  );
}

class _OnboardingEdgeGradient extends StatefulWidget {
  const _OnboardingEdgeGradient();

  @override
  State<_OnboardingEdgeGradient> createState() =>
      _OnboardingEdgeGradientState();
}

class _OnboardingEdgeGradientState extends State<_OnboardingEdgeGradient>
    with SingleTickerProviderStateMixin {
  late final motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      motion
        ..stop()
        ..value = 0;
    } else if (!motion.isAnimating) {
      motion.repeat();
    }
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => const RadialGradient(
          radius: .46,
          transform: _OvalGradientTransform(),
          colors: [Colors.white, Colors.white, Colors.transparent],
          stops: [0, .5, 1],
        ).createShader(bounds),
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: AnimatedBuilder(
            animation: motion,
            builder: (context, child) => Stack(
              fit: StackFit.expand,
              children: [
                _EdgeColor(_center(-1.25, -1.2, 0), const Color(0xfff25e6b)),
                _EdgeColor(_center(-.25, -1.25, 1), const Color(0xfff2c2ac)),
                _EdgeColor(_center(.35, -1.25, 2), const Color(0xffffd0b8)),
                _EdgeColor(_center(1.2, -1.05, 3), const Color(0xff96c4ff)),
                _EdgeColor(_center(1.25, .05, 4), const Color(0xffb9d6ff)),
                _EdgeColor(_center(1.2, 1.15, 5), const Color(0xffd3e081)),
                _EdgeColor(_center(.05, 1.25, 6), const Color(0xfff4d69f)),
                _EdgeColor(_center(-.75, 1.2, 7), const Color(0xfff2c2ac)),
                _EdgeColor(_center(-1.25, .45, 8), const Color(0xffff9a91)),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Alignment _center(double x, double y, int index) {
    final phase = motion.value * math.pi * 2 + index * .71;
    return Alignment(x + math.cos(phase) * .13, y + math.sin(phase * .83) * .1);
  }
}

class _OvalGradientTransform extends GradientTransform {
  const _OvalGradientTransform();

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final center = bounds.center;
    return Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(bounds.width / bounds.height, 1, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }
}

class _EdgeColor extends StatelessWidget {
  const _EdgeColor(this.center, this.color);

  final Alignment center;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: RadialGradient(
        center: center,
        radius: .65,
        colors: [color, color.withValues(alpha: 0)],
        stops: const [0, 1],
      ),
    ),
  );
}

class ProductionGate extends StatefulWidget {
  const ProductionGate({
    required this.configurationMessage,
    required this.auth,
    required this.capabilities,
    required this.onOpenPreview,
    required this.onFinish,
    super.key,
  });

  final String configurationMessage;
  final AuthController auth;
  final DesktopCapabilityGateway capabilities;
  final VoidCallback onOpenPreview;
  final FutureOr<void> Function() onFinish;

  @override
  State<ProductionGate> createState() => _ProductionGateState();
}

class _ProductionGateState extends State<ProductionGate>
    with WidgetsBindingObserver {
  static const permissionCapabilities = [
    CoreCapability.microphone,
    CoreCapability.screenCapture,
    CoreCapability.accessibility,
    CoreCapability.appData,
  ];
  Map<CoreCapability, CapabilityStatus> statuses = {
    for (final capability in CoreCapability.values)
      capability: const CapabilityStatus(
        state: CapabilityState.checking,
        detail: 'Checking capability…',
      ),
  };
  bool refreshing = false;
  bool finishing = false;
  bool finishFailed = false;
  final requesting = <CoreCapability>{};
  int checkGeneration = 0;
  Timer? permissionPoll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(_refreshView);
    unawaited(_check());
    _startPermissionPoll();
  }

  @override
  void dispose() {
    permissionPoll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.auth.removeListener(_refreshView);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !refreshing && !finishing) {
      unawaited(_check());
    }
  }

  void _refreshView() {
    if (mounted) setState(() {});
  }

  Future<void> _check() async {
    final generation = ++checkGeneration;
    setState(() => refreshing = true);
    Map<CoreCapability, CapabilityStatus> next;
    try {
      next = await widget.capabilities.check();
    } catch (error) {
      next = {
        for (final capability in CoreCapability.values)
          capability: CapabilityStatus(
            state: CapabilityState.error,
            detail: 'Could not check this capability: $error',
          ),
      };
    }
    if (!mounted || generation != checkGeneration) return;
    setState(() {
      statuses = next;
      refreshing = false;
    });
    if (ready) {
      permissionPoll?.cancel();
      permissionPoll = null;
      if (!finishing) await _finish();
    }
  }

  Future<void> _request(CoreCapability capability) async {
    if (!requesting.add(capability)) return;
    final generation = checkGeneration;
    if (mounted) setState(() {});
    try {
      await widget.capabilities.request(capability);
      if (!mounted || generation != checkGeneration) return;
      await _check();
      if (!ready) _startPermissionPoll();
    } catch (error) {
      if (!mounted || generation != checkGeneration) return;
      setState(() {
        statuses = {
          ...statuses,
          capability: CapabilityStatus(
            state: CapabilityState.error,
            detail: 'Could not request this capability: $error',
          ),
        };
      });
    } finally {
      requesting.remove(capability);
      if (mounted) setState(() {});
    }
  }

  void _startPermissionPoll() {
    permissionPoll ??= Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && !refreshing && !finishing) unawaited(_check());
    });
  }

  Future<void> _finish() async {
    if (finishing) return;
    setState(() {
      finishing = true;
      finishFailed = false;
    });
    try {
      await widget.onFinish();
      if (mounted) setState(() => finishing = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        finishing = false;
        finishFailed = true;
      });
    }
  }

  bool get ready => permissionCapabilities.every(
    (capability) => statuses[capability]?.acceptable == true,
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'First…',
        textAlign: TextAlign.left,
        style: TextStyle(
          color: Color(0xfffffcec),
          fontFamily: 'Avenir Next',
          fontSize: 38,
          fontWeight: FontWeight.w500,
          letterSpacing: -1.5,
        ),
      ),
      const SizedBox(height: 26),
      for (final capability in permissionCapabilities)
        _CapabilityRow(
          capability: capability,
          status: statuses[capability]!,
          onRequest:
              statuses[capability]!.state == CapabilityState.actionRequired &&
                  !requesting.contains(capability)
              ? () => unawaited(_request(capability))
              : null,
        ),
      if (finishFailed) ...[
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: const Text(
            'Onboarding completion could not be saved. Try again.',
            style: TextStyle(color: Color(0xffffb4ab)),
          ),
        ),
      ],
    ],
  );
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({
    required this.capability,
    required this.status,
    required this.onRequest,
  });

  final CoreCapability capability;
  final CapabilityStatus status;
  final VoidCallback? onRequest;

  @override
  Widget build(BuildContext context) {
    final copy = switch (capability) {
      CoreCapability.microphone =>
        'I would like to use your microphone so we can talk.',
      CoreCapability.screenCapture =>
        'I would like to see your screen so I can give relevant help.',
      CoreCapability.accessibility =>
        'I would like accessibility access so I can act when you ask.',
      CoreCapability.appData =>
        'I would like Full Disk Access to learn more about you.',
      CoreCapability.workspaceRoot => throw StateError(
        'Workspace selection is not an operating-system permission.',
      ),
    };
    final state = switch (status.state) {
      CapabilityState.checking => 'Checking',
      CapabilityState.granted => 'Granted',
      CapabilityState.actionRequired => 'Action required',
      CapabilityState.notRequired => 'No grant required',
      CapabilityState.notApplicable => 'Not applicable',
      CapabilityState.error => 'Check failed',
    };
    final granted = status.acceptable;
    return Semantics(
      button: true,
      enabled: onRequest != null,
      label: copy,
      value: granted ? 'Granted' : state,
      onTap: onRequest,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Material(
            color: const Color(0x0dffffff),
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onRequest,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: granted
                            ? const Color(0xfffffcec)
                            : Colors.transparent,
                        border: Border.all(color: const Color(0x73ffffff)),
                      ),
                      child: granted
                          ? const Icon(
                              Icons.check_rounded,
                              size: 14,
                              color: Color(0xff171716),
                            )
                          : null,
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Text(
                        copy,
                        style: const TextStyle(
                          color: Color(0xd1ffffff),
                          fontSize: 15,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      granted
                          ? 'Granted'
                          : onRequest == null
                          ? state
                          : 'Open',
                      style: const TextStyle(
                        color: Color(0x73ffffff),
                        fontSize: 12,
                      ),
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

class ProcessingConsentGate extends StatelessWidget {
  const ProcessingConsentGate({required this.auth, super.key});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final snapshot = auth.snapshot;
    final granted = snapshot.hasProcessingAuthority;
    final signedIn = snapshot.phase == AuthPhase.signedIn;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
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
