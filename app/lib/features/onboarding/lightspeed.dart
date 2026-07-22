import 'dart:math' as math;

import 'package:flutter/material.dart';

enum LightspeedMode { lightspeed, fade }

class LightspeedTransition extends StatefulWidget {
  const LightspeedTransition({
    required this.mode,
    required this.onCompleted,
    this.child,
    this.endColor,
    super.key,
  });

  final LightspeedMode mode;
  final VoidCallback onCompleted;
  final Widget? child;
  final Color? endColor;

  @override
  State<LightspeedTransition> createState() => _LightspeedTransitionState();
}

class _LightspeedTransitionState extends State<LightspeedTransition>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: widget.mode == LightspeedMode.lightspeed
        ? const Duration(milliseconds: 1500)
        : const Duration(milliseconds: 350),
  );
  bool completed = false;

  @override
  void initState() {
    super.initState();
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && !completed) {
        completed = true;
        widget.onCompleted();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      if (!completed) {
        completed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onCompleted();
        });
      }
    } else if (!controller.isAnimating && controller.value == 0) {
      controller.forward();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final endColor = widget.endColor;
      final settle = endColor == null
          ? 0.0
          : ((controller.value - .7) / .3).clamp(0.0, 1.0);
      return Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xff171716)),
          if (widget.mode == LightspeedMode.lightspeed)
            CustomPaint(
              key: const Key('lightspeed_paint'),
              painter: LightspeedPainter(progress: controller.value),
            )
          else
            Opacity(
              key: const Key('lightspeed_fade'),
              opacity: 1 - Curves.easeOut.transform(controller.value),
              child: const ColoredBox(color: Color(0x66000000)),
            ),
          if (endColor != null && settle > 0)
            Opacity(
              key: const Key('lightspeed_settle'),
              opacity: Curves.easeInOut.transform(settle),
              child: ColoredBox(color: endColor),
            ),
          if (widget.child case final child?) Center(child: child),
        ],
      );
    },
  );
}

class LightspeedPainter extends CustomPainter {
  LightspeedPainter({required this.progress});

  static const palette = [
    Color(0xfff25e6b),
    Color(0xfff2c2ac),
    Color(0xffffd0b8),
    Color(0xff96c4ff),
    Color(0xffb9d6ff),
    Color(0xffd3e081),
    Color(0xfff4d69f),
    Color(0xffff9a91),
  ];
  static const _streaks = 84;

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.longestSide * .72;
    final random = math.Random(7);
    final accelerated = Curves.easeInCubic.transform(progress.clamp(0, 1));
    for (var index = 0; index < _streaks; index += 1) {
      final angle = random.nextDouble() * math.pi * 2;
      final startFraction = .35 + random.nextDouble() * .65;
      final speed = .6 + random.nextDouble() * .9;
      final travel = (accelerated * speed).clamp(0.0, 1.0);
      final outer = maxRadius * startFraction * (1 - travel);
      final length =
          maxRadius * (.06 + .3 * accelerated) * (1 - travel) + maxRadius * .02;
      final inner = (outer - length).clamp(0.0, outer);
      if (outer <= maxRadius * .04) continue;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final color = palette[index % palette.length];
      final fade = (1 - travel) * (accelerated < .1 ? accelerated / .1 : 1);
      final paint = Paint()
        ..color = color.withValues(alpha: (.85 * fade).clamp(0.0, 1.0))
        ..strokeWidth = 1.6 + 1.8 * accelerated
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        center + direction * inner,
        center + direction * outer,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(LightspeedPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
