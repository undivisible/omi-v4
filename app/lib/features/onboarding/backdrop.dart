import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class OnboardingBackdrop extends StatelessWidget {
  const OnboardingBackdrop({
    required this.child,
    required this.bright,
    super.key,
  });

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
