import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'omi_orb_motion.dart';

export 'omi_orb_motion.dart';

/// Holds the mark still under `flutter test`. A perpetual rotation never lets
/// `pumpAndSettle` return, so every widget test that settles a screen holding
/// the mark would hang; `test/flutter_test_config.dart` flips this true. In
/// production it stays false and the mark always turns.
bool debugOmiOrbStatic = false;

/// How long the mark takes to cross from one motion to the next.
const Duration omiOrbMorphDuration = Duration(milliseconds: 240);

/// The omi mark — the ring of eight dots from the brand logo, drawn dot by dot
/// so it can breathe, think, listen and celebrate. It is the greeter avatar,
/// the assistant's chat profile picture, and (as [OmiActivityOrb.loading]) the
/// loading indicator, so the same identity carries every waiting state.
class OmiActivityOrb extends StatefulWidget {
  const OmiActivityOrb({
    this.size = 46,
    this.period = const Duration(seconds: 8),
    this.state = OmiOrbState.idle,
    this.motion,
    this.amplitude = 0,
    this.color,
    super.key,
  });

  /// The loading cadence: the same mark, its highlight walking the ring at the
  /// tighter site pulse (`.omi-mark.is-tight`, 1.7s).
  const OmiActivityOrb.loading({double size = 46, Color? color, Key? key})
    : this(
        size: size,
        period: const Duration(milliseconds: 1700),
        state: OmiOrbState.thinking,
        color: color,
        key: key,
      );

  final double size;

  /// One full lap of the current motion takes this long. The idle greeter turns
  /// slowly; the loading constructor tightens the pulse to match the site.
  final Duration period;

  /// What the mark is expressing. Picks the motion unless [motion] overrides it.
  final OmiOrbState state;

  /// The choreography to run, when a surface wants one the product states do
  /// not reach for — a showcase idle, a nested-circle wait. Null follows
  /// [state] through [omiMotionForState].
  final OmiOrbMotion? motion;

  /// For [OmiOrbState.listening]: the current input level, 0 to 1. The wave
  /// grows out of the ring with it, so the mark is the level meter.
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

  late OmiOrbMotion _motion = _requested;

  /// The frame the previous motion was showing when it was interrupted, held so
  /// the new one can be crossed into rather than cut to. Null once the cross is
  /// finished.
  List<OmiDotPlacement>? _from;
  double _morph = 1;

  OmiOrbMotion get _requested =>
      widget.motion ?? omiMotionForState(widget.state);

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
    if (_morph < 1) {
      _morph = math.min(
        1,
        _morph + dt / (omiOrbMorphDuration.inMicroseconds / 1e6),
      );
      if (_morph >= 1) _from = null;
    }
  }

  /// Freezes the motion being abandoned and starts crossing into [next]. The
  /// frozen frame is a plain list of placements, so an interruption partway
  /// through a previous cross carries the blended pose forward instead of
  /// snapping back to the motion it had already half-left.
  void _crossTo(OmiOrbMotion next) {
    _from = _placementsNow();
    _motion = next;
    _morph = 0;
  }

  List<OmiDotPlacement> _placementsNow() {
    final current = omiOrbPlacements(
      motion: _motion,
      turn: _clock.value,
      level: _level,
      burst: _burst,
    );
    final previous = _from;
    if (previous == null || _morph >= 1) return current;
    final t = Curves.easeOutCubic.transform(_morph.clamp(0.0, 1.0));
    return List<OmiDotPlacement>.generate(
      OmiMarkGeometry.dotCount,
      (i) => OmiDotPlacement.lerp(previous[i], current[i], t),
      growable: false,
    );
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
    if (_requested != _motion) {
      if (_reduceMotion) {
        _motion = _requested;
        _from = null;
        _morph = 1;
      } else {
        _crossTo(_requested);
      }
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
      _from = null;
      _morph = 1;
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
              painter: OmiMarkPainter(
                placements: still
                    ? omiOrbPlacements(motion: OmiOrbMotion.mark, turn: 0)
                    : _placementsNow(),
                color: widget.color ?? DefaultTextStyle.of(context).style.color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws eight dots wherever a motion put them. It knows nothing about states
/// or choreography: hand it placements in the mark's canvas space and it draws
/// the mark, which is what lets the cold open reuse it at full-screen size.
class OmiMarkPainter extends CustomPainter {
  const OmiMarkPainter({
    required this.placements,
    required this.color,
    this.centre,
    this.unit,
    this.opacity = 1,
  });

  final List<OmiDotPlacement> placements;
  final Color? color;

  /// Where the ring centre lands. Defaults to the middle of the canvas.
  final Offset? centre;

  /// Canvas units per logical pixel. Defaults to fitting the 260-unit mark to
  /// the shortest side.
  final double? unit;

  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final ink = color ?? const Color(0xFFFFFCEC);
    final scale = unit ?? size.shortestSide / OmiMarkGeometry.canvas;
    final origin = centre ?? Offset(size.width / 2, size.height / 2);

    final glow = Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 9 * scale);
    final body = Paint();

    for (final dot in placements) {
      final alpha = (dot.alpha * opacity).clamp(0.0, 1.0);
      if (alpha <= 0) continue;
      final at = origin + dot.offset * scale;
      final r = OmiMarkGeometry.dotRadius * scale * dot.scale;

      canvas.drawCircle(
        at,
        r * 1.05,
        glow..color = ink.withValues(alpha: 0.3 * alpha),
      );
      canvas.drawCircle(at, r, body..color = ink.withValues(alpha: alpha));
    }
  }

  @override
  bool shouldRepaint(OmiMarkPainter old) =>
      !identical(old.placements, placements) ||
      old.color != color ||
      old.centre != centre ||
      old.unit != unit ||
      old.opacity != opacity;
}
