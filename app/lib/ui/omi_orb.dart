import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Holds the mark still under `flutter test`. A perpetual rotation never lets
/// `pumpAndSettle` return, so every widget test that settles a screen holding
/// the mark would hang; `test/flutter_test_config.dart` flips this true. In
/// production it stays false and the mark always turns.
bool debugOmiOrbStatic = false;

/// What the mark is doing. The geometry never changes — only how the eight
/// dots move — so the identity carries every state instead of being swapped
/// out for a spinner, a waveform and a checkmark.
enum OmiOrbState {
  /// At rest: a slow orbit and a barely-there breath.
  idle,

  /// Working: a single highlight travelling around the ring.
  thinking,

  /// Hearing you: the ring swells and shrinks with [OmiActivityOrb.amplitude].
  listening,

  /// Done: the dots scatter outward once and re-form.
  success,
}

/// The geometry of the Omi mark, measured from `assets/images/omi_logo.png`
/// and kept identical to `assets/images/omi_mark.svg`, the source of truth.
///
/// The artwork is 260x260 with the ring centred at (129.5, 129.5) and every
/// dot 17.2 units across the radius. The four dots on the axes sit at radius
/// 86.71 and the four on the diagonals at 91.92 — the mark is a rounded
/// square rather than a true circle, and that is deliberate, so it is kept.
///
/// Dot order matches the SVG: index 0 is due north, and the rest run
/// clockwise (0 = 12 o'clock, 1 = 1:30, 2 = 3 o'clock … 7 = 10:30).
@visibleForTesting
class OmiMarkGeometry {
  const OmiMarkGeometry._();

  static const double canvas = 260;
  static const double centre = 129.5;
  static const double dotRadius = 17.2;
  static const double axisRadius = 86.71;
  static const double diagonalRadius = 91.92;
  static const int dotCount = 8;

  /// Distance from the centre to dot [i] in canvas units.
  static double radiusOf(int i) => i.isEven ? axisRadius : diagonalRadius;

  /// The angle of dot [i], measured clockwise from due north.
  static double angleOf(int i) => i * math.pi / 4;
}

/// The omi mark — the ring of eight dots from the brand logo, drawn dot by dot
/// so it can breathe, think, listen and celebrate. It is the greeter avatar,
/// the assistant's chat profile picture, and (as [OmiActivityOrb.loading]) the
/// loading indicator, so the same identity carries every waiting state.
class OmiActivityOrb extends StatefulWidget {
  const OmiActivityOrb({
    this.size = 46,
    this.period = const Duration(seconds: 8),
    this.state = OmiOrbState.idle,
    this.amplitude = 0,
    this.color,
    super.key,
  });

  /// The loading cadence: the same mark, its highlight travelling fast enough
  /// to read as activity.
  const OmiActivityOrb.loading({double size = 46, Color? color, Key? key})
    : this(
        size: size,
        period: const Duration(milliseconds: 1100),
        state: OmiOrbState.thinking,
        color: color,
        key: key,
      );

  final double size;

  /// One full turn of the ring — and one full lap of the thinking highlight —
  /// takes this long. The idle greeter turns slowly; the loading constructor
  /// turns it fast.
  final Duration period;

  /// What the mark is expressing.
  final OmiOrbState state;

  /// For [OmiOrbState.listening]: the current input level, 0 to 1. The ring
  /// breathes outward with it, so the mark is the level meter.
  final double amplitude;

  /// Defaults to the ambient text colour, so the mark sits in whatever surface
  /// it is placed on.
  final Color? color;

  @override
  State<OmiActivityOrb> createState() => _OmiActivityOrbState();
}

class _OmiActivityOrbState extends State<OmiActivityOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: widget.period,
  );

  /// Eased toward [OmiActivityOrb.amplitude] every frame so a jumpy input
  /// level still reads as a smooth swell.
  double _level = 0;

  /// Progress through the one-shot scatter-and-reform, 0 to 1.
  double _burst = 1;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _clock.addListener(_advance);
    if (widget.state == OmiOrbState.success) _burst = 0;
  }

  void _advance() {
    final now = _clock.lastElapsedDuration ?? Duration.zero;
    var dt = (now - _lastTick).inMicroseconds / 1e6;
    _lastTick = now;
    // The controller restarts each lap, so a wrapped or absurd delta is normal.
    if (dt <= 0 || dt > 0.05) dt = 1 / 60;

    final target = widget.state == OmiOrbState.listening
        ? widget.amplitude.clamp(0.0, 1.0)
        : 0.0;
    // A critically damped follow: quick to rise, no overshoot.
    _level += (target - _level) * (1 - math.pow(0.002, dt));
    if (_burst < 1) _burst = math.min(1, _burst + dt / 0.9);
  }

  @override
  void didUpdateWidget(covariant OmiActivityOrb old) {
    super.didUpdateWidget(old);
    if (old.period != widget.period) {
      _clock.duration = widget.period;
      if (_clock.isAnimating) _clock.repeat();
    }
    if (old.state != widget.state && widget.state == OmiOrbState.success) {
      _burst = 0;
    }
    _syncMotion();
  }

  bool get _reduceMotion =>
      debugOmiOrbStatic ||
      (MediaQuery.maybeOf(context)?.disableAnimations ?? false);

  void _syncMotion() {
    // Honour the platform "reduce motion" setting: a mark that never stops
    // moving is exactly what that setting exists to quiet. Stopping the only
    // controller also guarantees `pumpAndSettle` can return under test.
    if (_reduceMotion) {
      if (_clock.isAnimating) _clock.stop();
      _level = 0;
      _burst = 1;
    } else if (!_clock.isAnimating) {
      _lastTick = Duration.zero;
      _clock.repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = _reduceMotion;
    return Semantics(
      label: 'Omi',
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: AnimatedBuilder(
            animation: _clock,
            builder: (context, _) => CustomPaint(
              painter: _OmiMarkPainter(
                turn: still ? 0 : _clock.value,
                state: still ? OmiOrbState.idle : widget.state,
                level: still ? 0 : _level,
                burst: still ? 1 : _burst,
                still: still,
                color: widget.color ?? DefaultTextStyle.of(context).style.color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OmiMarkPainter extends CustomPainter {
  const _OmiMarkPainter({
    required this.turn,
    required this.state,
    required this.level,
    required this.burst,
    required this.still,
    required this.color,
  });

  /// Position within the current lap, 0 to 1.
  final double turn;
  final OmiOrbState state;
  final double level;
  final double burst;
  final bool still;
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    final ink = color ?? const Color(0xFFFFFCEC);
    final unit = size.shortestSide / OmiMarkGeometry.canvas;
    final centre = Offset(size.width / 2, size.height / 2);

    // The whole ring orbits. Idle turns once per lap; the other states hold
    // steadier so the per-dot motion is what reads.
    final spin = switch (state) {
      OmiOrbState.idle => turn,
      OmiOrbState.thinking => turn * 0.25,
      OmiOrbState.listening => turn * 0.12,
      OmiOrbState.success => turn * 0.5,
    };
    final spinAngle = still ? 0.0 : spin * 2 * math.pi;

    // Scatter-and-reform: everything flies out at once and settles back with
    // an eased return, so the ring snaps home rather than drifting home.
    final eased = Curves.easeOutBack.transform(burst.clamp(0.0, 1.0));
    final scatter = burst >= 1 ? 0.0 : math.sin(burst * math.pi) * 34;

    final glow = Paint()
      ..color = ink.withValues(alpha: 0.34)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 9 * unit);
    final body = Paint()..color = ink;

    for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
      final phase = _phaseOf(i);
      final radius =
          OmiMarkGeometry.radiusOf(i) +
          scatter +
          level * 13 * (0.55 + 0.45 * phase);
      final angle = OmiMarkGeometry.angleOf(i) + spinAngle;

      // Canvas y grows downward and index 0 is due north, so north is -y.
      final at =
          centre + Offset(math.sin(angle), -math.cos(angle)) * radius * unit;

      final scale = 1 + phase * 0.16 + level * 0.1;
      final alpha =
          (0.6 + phase * 0.4) * (burst >= 1 ? 1.0 : eased.clamp(0.0, 1.0));
      final r = OmiMarkGeometry.dotRadius * unit * scale;

      canvas.drawCircle(
        at,
        r * 1.05,
        glow..color = ink.withValues(alpha: 0.3 * alpha),
      );
      canvas.drawCircle(at, r, body..color = ink.withValues(alpha: alpha));
    }
  }

  /// How lit dot [i] is right now, 0 to 1.
  double _phaseOf(int i) {
    if (still) return 0;
    switch (state) {
      case OmiOrbState.idle:
        // A shared breath, offset a little around the ring so the mark never
        // pulses as one flat blob.
        final t = (turn + i / OmiMarkGeometry.dotCount / 3) % 1;
        return 0.35 * (0.5 - 0.5 * math.cos(t * 2 * math.pi));
      case OmiOrbState.thinking:
        // One highlight travelling the ring: distance from the moving head,
        // measured the short way round.
        final head = turn * OmiMarkGeometry.dotCount;
        var d = (i - head) % OmiMarkGeometry.dotCount;
        if (d > OmiMarkGeometry.dotCount / 2) d = OmiMarkGeometry.dotCount - d;
        return math.max(0, 1 - d / 2.2);
      case OmiOrbState.listening:
        return level;
      case OmiOrbState.success:
        return burst >= 1 ? 0.25 : 1 - burst;
    }
  }

  @override
  bool shouldRepaint(_OmiMarkPainter old) =>
      old.turn != turn ||
      old.state != state ||
      old.level != level ||
      old.burst != burst ||
      old.still != still ||
      old.color != color;
}
