import 'dart:math' as math;

import 'package:flutter/material.dart';

enum OmiOrbState { idle, listening, thinking, speaking }

class OmiActivityOrb extends StatefulWidget {
  const OmiActivityOrb({required this.state, this.size = 46, super.key});

  final OmiOrbState state;
  final double size;

  @override
  State<OmiActivityOrb> createState() => _OmiActivityOrbState();
}

class _OmiActivityOrbState extends State<OmiActivityOrb>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  bool get _active => widget.state != OmiOrbState.idle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(OmiActivityOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  void _syncMotion() {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_active && !reducedMotion) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: switch (widget.state) {
        OmiOrbState.idle => 'Omi idle',
        OmiOrbState.listening => 'Omi listening',
        OmiOrbState.thinking => 'Omi thinking',
        OmiOrbState.speaking => 'Omi speaking',
      },
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: _active ? 1 : 0),
            duration: reducedMotion
                ? Duration.zero
                : const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            builder: (context, morph, child) => AnimatedBuilder(
              animation: _motion,
              builder: (context, child) => Stack(
                fit: StackFit.expand,
                children: [
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xfffffcec), Color(0xffe9e4cf)],
                      ),
                      boxShadow: [
                        BoxShadow(color: Color(0x40fffcec), blurRadius: 30),
                      ],
                    ),
                  ),
                  CustomPaint(
                    painter: OmiOrbPainter(
                      state: widget.state,
                      phase: reducedMotion ? 0 : _motion.value,
                      morph: morph,
                    ),
                  ),
                  Opacity(
                    opacity: 1 - morph,
                    child: const Icon(
                      Icons.blur_on_rounded,
                      color: Color(0xff171716),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OmiOrbPainter extends CustomPainter {
  const OmiOrbPainter({
    required this.state,
    required this.phase,
    required this.morph,
  });

  final OmiOrbState state;
  final double phase;
  final double morph;

  @override
  void paint(Canvas canvas, Size size) {
    if (morph <= 0) return;
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * .31;
    final color = switch (state) {
      OmiOrbState.listening => const Color(0xffe3fff6),
      OmiOrbState.thinking => const Color(0xffe4efff),
      OmiOrbState.speaking => const Color(0xffffe5d8),
      OmiOrbState.idle => const Color(0xffe3fff6),
    };
    final glow = Paint()
      ..color = color.withValues(alpha: .13 * morph)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
    canvas.drawCircle(center, radius * 1.15, glow);

    final paint = Paint()..style = PaintingStyle.fill;
    for (var index = 0; index < 16; index += 1) {
      final angle = (index / 16 * math.pi * 2) + phase * math.pi * 2;
      final point = _point(center, radius, angle, index);
      final depth = .55 + .45 * ((math.sin(angle) + 1) / 2);
      paint.color = color.withValues(alpha: morph * depth);
      canvas.drawCircle(point, 1 + depth * .8, paint);
    }
  }

  Offset _point(Offset center, double radius, double angle, int index) =>
      switch (state) {
        OmiOrbState.listening => Offset(
          center.dx +
              math.cos(angle) *
                  radius *
                  (.78 + .12 * math.sin(phase * math.pi * 2)),
          center.dy + math.sin(angle) * radius * .82,
        ),
        OmiOrbState.thinking => Offset(
          center.dx + math.cos(angle) * radius,
          center.dy +
              math.sin(angle) *
                  radius *
                  (.42 + .22 * math.sin(angle * 2 + phase * math.pi * 2)),
        ),
        OmiOrbState.speaking => Offset(
          center.dx + math.cos(angle) * radius * .88,
          center.dy +
              math.sin(angle) *
                  radius *
                  (.55 + .24 * math.sin(index * 1.7 + phase * math.pi * 4)),
        ),
        OmiOrbState.idle => center,
      };

  @override
  bool shouldRepaint(OmiOrbPainter oldDelegate) =>
      state != oldDelegate.state ||
      phase != oldDelegate.phase ||
      morph != oldDelegate.morph;
}
