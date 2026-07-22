import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class OnboardingBackdrop extends StatefulWidget {
  const OnboardingBackdrop({
    required this.child,
    required this.bright,
    required this.searching,
    required this.settled,
    this.baseColor,
    super.key,
  });

  final Widget child;
  final bool bright;
  final bool searching;
  final bool settled;
  final Color? baseColor;

  @override
  State<OnboardingBackdrop> createState() => _OnboardingBackdropState();
}

class _OnboardingBackdropState extends State<OnboardingBackdrop> {
  bool entered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => entered = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.baseColor case final color?)
          ColoredBox(color: color)
        else if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS)
          const ColoredBox(color: Color(0xff9ba0a3)),
        AnimatedOpacity(
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 900),
          curve: Curves.easeOutCubic,
          opacity: entered ? (widget.bright ? .74 : .16) : 0,
          child: TweenAnimationBuilder<double>(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 1800),
            curve: Curves.easeOutCubic,
            tween: Tween(end: widget.bright ? 1 : 0),
            builder: (context, rise, child) => _OnboardingEdgeGradient(
              rise: rise,
              active: widget.searching,
              settled: widget.settled,
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _OnboardingEdgeGradient extends StatefulWidget {
  const _OnboardingEdgeGradient({
    required this.rise,
    required this.active,
    required this.settled,
  });

  final double rise;
  final bool active;
  final bool settled;

  @override
  State<_OnboardingEdgeGradient> createState() =>
      _OnboardingEdgeGradientState();
}

class _OnboardingEdgeGradientState extends State<_OnboardingEdgeGradient>
    with SingleTickerProviderStateMixin {
  late final motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(_OnboardingEdgeGradient oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncMotion();
  }

  void _syncMotion() {
    if (widget.active && !MediaQuery.disableAnimationsOf(context)) {
      if (!motion.isAnimating) motion.repeat();
    } else {
      motion.stop();
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
      child: TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        tween: Tween(end: widget.settled ? 1 : 0),
        builder: (context, clarity, child) => ShaderMask(
          key: const Key('onboarding_gradient_mask'),
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => RadialGradient(
            radius: .46,
            transform: const _OvalGradientTransform(),
            colors: [
              Colors.white.withValues(alpha: 1 - clarity * .82),
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            stops: const [0, .54, .72, 1],
          ).createShader(bounds),
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: AnimatedBuilder(
              animation: motion,
              builder: (context, child) => Stack(
                key: const Key('onboarding_gradient_colors'),
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
    ),
  );

  Alignment _center(double x, double y, int index) {
    final phase = motion.value * math.pi * 2 + index * .71;
    return Alignment(
      x + math.cos(phase) * .16,
      y + (1 - widget.rise) * .72 + math.sin(phase * .83) * .12,
    );
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
