import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

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

  /// The unit vector pointing at [angle], clockwise from due north. Canvas y
  /// grows downward, so north is -y.
  static Offset directionAt(double angle) =>
      Offset(math.sin(angle), -math.cos(angle));

  /// Where dot [i] sits at rest, measured from the ring centre.
  static Offset restOf(int i) => directionAt(angleOf(i)) * radiusOf(i);

  /// Dot [i]'s position in the wave chain, left to right.
  ///
  /// The ring is cut between due south and its south-west neighbour and
  /// unrolled clockwise, so lane order is SW, W, NW, N, NE, E, SE, S. Because
  /// the chain follows ring order, a phase that runs along the lanes is the
  /// same phase running around the ring: a travelling wave stays a travelling
  /// wave through the morph rather than scrambling into it.
  static int laneOf(int i) => (i + 3) % dotCount;

  /// Half the width the wave layouts spread across, in canvas units.
  static const double laneSpan = 92;

  /// Dots shrink to this on the chain. Eight dots at full size across the span
  /// overlap by more than half their width and the wave reads as one blob;
  /// this is the largest they can be and still leave daylight between them.
  static const double laneDotScale = 0.68;

  /// The x of dot [i]'s lane, measured from the ring centre.
  static double laneXOf(int i) =>
      (laneOf(i) / (dotCount - 1) - 0.5) * 2 * laneSpan;

  /// The resting y of dot [i]'s lane. A shallow arc rather than a dead flat
  /// rule, so the flattened chain keeps a memory of the ring it came from.
  static double laneYOf(int i) {
    final t = laneXOf(i) / laneSpan;
    return 7 * t * t - 2;
  }
}

/// What the mark is doing. The geometry never changes — only how the eight
/// dots move — so the identity carries every state instead of being swapped
/// out for a spinner, a waveform and a checkmark.
enum OmiOrbState {
  /// At rest: a slow orbit and a barely-there breath.
  idle,

  /// Working: a highlight walks d1 -> d8 around the ring, one dot at a time.
  thinking,

  /// Hearing you: the chain flattens into a travelling wave whose amplitude
  /// is [OmiActivityOrb.amplitude].
  listening,

  /// Done: the dots scatter outward once and re-form.
  success,
}

/// One choreography the eight dots can perform.
///
/// Every entry is a closed-form function of the lap position, so any two of
/// them can be blended by interpolating their output — that is what lets the
/// mark change its mind mid-cycle without snapping.
enum OmiOrbMotion {
  /// Brand rest: the ring, a slow orbit and a shared breath.
  mark,

  /// The bare orbit, no breath — the original idle, kept as a fallback.
  spin,

  /// The site thinking pulse: a highlight walking a stationary ring.
  pulse,

  /// The dots fall inward into a knot and spring back out past rest.
  gather,

  /// The ring flattens into a chain carrying a travelling sine, the amplitude
  /// and the depth of the flattening both driven by the input level.
  sine,

  /// A packet of energy visibly runs along the chain, left to right.
  travellingWave,

  /// Neighbours in antiphase: the nodes hold still, the antinodes breathe.
  standingWave,

  /// Eight periods, one apart, so the chain runs sine -> travelling -> chaos
  /// -> line -> back over a single lap.
  pendulumWave,

  /// The pendulum wave run along Tusi diameters instead of lanes: each dot
  /// slides through the centre on its own line at its own rate, so the ring
  /// blooms into a turning lattice and reassembles itself at the lap mark.
  tusiPendulum,

  /// Beads riding the tops of eight level bars.
  audioBars,

  /// The Tusi couple: a circle rolling inside a circle at twice the rate, so
  /// every dot's path is a straight diameter. The circle drawing a line.
  tusi,

  /// A smaller circle rolls around the inside of the mark, dots riding its rim.
  nestedOrbit,

  /// The four axis dots hold the mark while the four diagonals collapse onto a
  /// tighter concentric ring and counter-rotate.
  doubleCircle,

  /// A small circle rolls around the outside, one dot leading and the rest
  /// trailing it.
  epicycloid,

  /// x and y sines at a 2:3 ratio, kept inside the mark's bounds.
  lissajous,

  /// The whole mark hangs and swings, the dots dragging behind the swing.
  pendulumSwing,

  /// The one-shot scatter and re-form.
  successBurst,
}

/// Where dot `i` sits this frame, measured from the ring centre in the mark's
/// 260-unit canvas space. Painters scale it; tests read it directly.
@immutable
class OmiDotPlacement {
  const OmiDotPlacement({
    required this.offset,
    required this.scale,
    required this.alpha,
  });

  /// Displacement from the ring centre, in canvas units.
  final Offset offset;

  /// Multiplies [OmiMarkGeometry.dotRadius].
  final double scale;

  final double alpha;

  static OmiDotPlacement lerp(OmiDotPlacement a, OmiDotPlacement b, double t) =>
      OmiDotPlacement(
        offset: Offset.lerp(a.offset, b.offset, t)!,
        scale: a.scale + (b.scale - a.scale) * t,
        alpha: a.alpha + (b.alpha - a.alpha) * t,
      );
}

/// The site thinking pulse: `@keyframes omi-dot-pulse` in `site/web/styles.css`.
/// Each dot peaks at 12% of its cycle, holds dim until 70%, then rests — staggered
/// by one eighth so the highlight reads as a single point of light walking the ring.
@visibleForTesting
class OmiThinkingPulse {
  const OmiThinkingPulse._();

  static const _ease = Cubic(0.22, 1, 0.36, 1);
  static const baseOpacity = 0.62;
  static const peakOpacity = 1.0;
  static const baseScale = 1.0;
  static const peakScale = 1.14;
  static const peakAt = 0.12;
  static const holdUntil = 0.70;

  /// Local phase for dot [i] within the current lap, 0 to 1.
  static double localPhase(int i, double turn) =>
      (turn + (OmiMarkGeometry.dotCount - i) / OmiMarkGeometry.dotCount) % 1;

  /// Opacity and scale at [localT], matching the site keyframes.
  static (double opacity, double scale) at(double localT) {
    if (localT <= peakAt) {
      final t = _ease.transform(localT / peakAt);
      return (
        baseOpacity + (peakOpacity - baseOpacity) * t,
        baseScale + (peakScale - baseScale) * t,
      );
    }
    if (localT <= holdUntil) {
      final t = _ease.transform((localT - peakAt) / (holdUntil - peakAt));
      return (
        peakOpacity + (baseOpacity - peakOpacity) * t,
        peakScale + (baseScale - peakScale) * t,
      );
    }
    return (baseOpacity, baseScale);
  }
}

const double _tau = math.pi * 2;

/// The choreography [state] performs unless a caller names a motion outright.
OmiOrbMotion omiMotionForState(OmiOrbState state) => switch (state) {
  OmiOrbState.idle => OmiOrbMotion.mark,
  OmiOrbState.thinking => OmiOrbMotion.pulse,
  OmiOrbState.listening => OmiOrbMotion.sine,
  OmiOrbState.success => OmiOrbMotion.successBurst,
};

/// Every dot's placement for one frame of [motion].
///
/// [turn] is the position within the current lap, 0 to 1. [level] is the input
/// level for the motions that meter one and is ignored by the rest. [burst] is
/// the progress of the one-shot scatter, 1 when it is not running.
List<OmiDotPlacement> omiOrbPlacements({
  required OmiOrbMotion motion,
  required double turn,
  double level = 0,
  double burst = 1,
}) => List<OmiDotPlacement>.generate(
  OmiMarkGeometry.dotCount,
  (i) => omiDotPlacement(
    motion: motion,
    index: i,
    turn: turn,
    level: level,
    burst: burst,
  ),
  growable: false,
);

/// One dot's placement for one frame. Split out from [omiOrbPlacements] so a
/// test can ask about a single dot's path without allocating the ring.
OmiDotPlacement omiDotPlacement({
  required OmiOrbMotion motion,
  required int index,
  required double turn,
  double level = 0,
  double burst = 1,
}) {
  final i = index;
  final rest = OmiMarkGeometry.radiusOf(i);
  final theta = OmiMarkGeometry.angleOf(i);
  final lift = level.clamp(0.0, 1.0);

  switch (motion) {
    case OmiOrbMotion.mark:
      // A shared breath, offset a little around the ring so the mark never
      // pulses as one flat blob, over the slow orbit it has always had.
      final breath =
          0.5 -
          0.5 *
              math.cos(_tau * ((turn + i / OmiMarkGeometry.dotCount / 3) % 1));
      return OmiDotPlacement(
        offset:
            OmiMarkGeometry.directionAt(theta + turn * _tau) *
            (rest + 2.2 * breath),
        scale: 1 + 0.056 * breath + 0.1 * lift,
        alpha: 0.6 + 0.4 * breath,
      );

    case OmiOrbMotion.spin:
      return OmiDotPlacement(
        offset: OmiMarkGeometry.directionAt(theta + turn * _tau) * rest,
        scale: 1,
        alpha: 0.84,
      );

    case OmiOrbMotion.pulse:
      final pulse = OmiThinkingPulse.at(OmiThinkingPulse.localPhase(i, turn));
      return OmiDotPlacement(
        offset: OmiMarkGeometry.restOf(i),
        scale: pulse.$2 + 0.1 * lift,
        alpha: pulse.$1,
      );

    case OmiOrbMotion.gather:
      // Pulled in hard, released with an overshoot that carries the dots past
      // their rest radius before they settle — a knot let go, not a knot faded.
      final t = (turn + i * 0.018) % 1;
      final double squeeze;
      if (t < 0.34) {
        squeeze = Curves.easeInCubic.transform(t / 0.34);
      } else if (t < 0.82) {
        squeeze = 1 - Curves.easeOutBack.transform((t - 0.34) / 0.48);
      } else {
        squeeze = 0;
      }
      return OmiDotPlacement(
        offset:
            OmiMarkGeometry.directionAt(theta + turn * _tau) *
            (rest * (1 - 0.86 * squeeze)),
        scale: 1 + 0.24 * squeeze.clamp(0.0, 1.0),
        alpha: 0.62 + 0.38 * (1 - 0.5 * squeeze.clamp(0.0, 1.0)),
      );

    case OmiOrbMotion.sine:
      // Silence leaves the ring standing with a shallow radial ripple; speech
      // flattens it into the chain and drives the amplitude. The morph and the
      // amplitude are both the level, so the wave grows out of the mark rather
      // than replacing it.
      final morph = Curves.easeOutCubic.transform((lift * 1.7).clamp(0.0, 1.0));
      final phase =
          _tau *
          (turn * omiSineTravelsPerLap -
              OmiMarkGeometry.laneOf(i) * omiSineLanePhase);
      final swing = math.sin(phase);
      final ring =
          OmiMarkGeometry.directionAt(theta) *
          (rest +
              3 * math.sin(_tau * (turn * 2 - i / OmiMarkGeometry.dotCount)));
      final wave = Offset(
        OmiMarkGeometry.laneXOf(i),
        OmiMarkGeometry.laneYOf(i) - (12 + 60 * lift) * swing,
      );
      final ringScale = 1 + 0.1 * lift;
      final waveScale =
          OmiMarkGeometry.laneDotScale +
          0.1 * lift +
          0.14 * (0.5 + 0.5 * swing);
      return OmiDotPlacement(
        offset: Offset.lerp(ring, wave, morph)!,
        scale: ringScale + (waveScale - ringScale) * morph,
        alpha: 0.64 + 0.36 * (0.5 + 0.5 * swing),
      );

    case OmiOrbMotion.travellingWave:
      // A gaussian packet running the chain, so the energy is somewhere rather
      // than everywhere: the dots it has left are calm, the dots ahead of it
      // have not moved yet.
      final lane = OmiMarkGeometry.laneOf(i) / (OmiMarkGeometry.dotCount - 1);
      final head = (turn * 2) % 1;
      final gap = (lane - head).abs();
      final distance = math.min(gap, 1 - gap);
      final envelope = math.exp(-(distance * distance) / (2 * 0.16 * 0.16));
      final swing = math.sin(_tau * (turn * 3 - lane * 2));
      return OmiDotPlacement(
        offset: Offset(
          OmiMarkGeometry.laneXOf(i),
          OmiMarkGeometry.laneYOf(i) - (26 + 44 * lift) * envelope * swing,
        ),
        scale: OmiMarkGeometry.laneDotScale + 0.26 * envelope,
        alpha: 0.55 + 0.45 * envelope,
      );

    case OmiOrbMotion.standingWave:
      // Three half-wavelengths pinned across the chain: the shape is fixed in
      // space and only its amplitude moves, which is what makes the nodes read.
      final lane = OmiMarkGeometry.laneOf(i) / (OmiMarkGeometry.dotCount - 1);
      final shape = math.sin(math.pi * lane * 3);
      final beat = math.sin(_tau * turn * 2);
      return OmiDotPlacement(
        offset: Offset(
          OmiMarkGeometry.laneXOf(i),
          OmiMarkGeometry.laneYOf(i) - (24 + 40 * lift) * shape * beat,
        ),
        scale: OmiMarkGeometry.laneDotScale + 0.2 * (shape * beat).abs(),
        alpha: 0.58 + 0.42 * (shape * beat).abs(),
      );

    case OmiOrbMotion.pendulumWave:
      // Nine through sixteen swings per lap. Every count is a whole number, so
      // the chain is a flat line again exactly at the lap mark and the desync
      // in between is the whole trick.
      final swings = _pendulumBase + OmiMarkGeometry.laneOf(i);
      final swing = math.sin(_tau * swings * turn);
      return OmiDotPlacement(
        offset: Offset(
          OmiMarkGeometry.laneXOf(i),
          OmiMarkGeometry.laneYOf(i) - (34 + 30 * lift) * swing,
        ),
        scale: OmiMarkGeometry.laneDotScale + 0.16 * swing.abs(),
        alpha: 0.6 + 0.4 * swing.abs(),
      );

    case OmiOrbMotion.tusi:
      // cos(wt + phase) along the dot's own diameter is the degenerate
      // hypocycloid: a circle of half the radius rolling inside the ring at
      // twice the rate, tracing a straight line. The stagger is half the dot's
      // angle, not the whole of it: a full-angle stagger puts opposite dots on
      // the same point for the entire cycle and the ring only ever shows four.
      final slide = math.cos(_tau * turn * 2 + theta / 2);
      return OmiDotPlacement(
        offset: OmiMarkGeometry.directionAt(theta) * (rest * slide),
        scale: 1 + 0.14 * (1 - slide.abs()),
        alpha: 0.55 + 0.45 * slide.abs(),
      );

    case OmiOrbMotion.tusiPendulum:
      // The same diameters, detuned: five through twelve slides per lap. Every
      // dot is still drawing a straight line and every count is still whole, so
      // the lattice tears itself apart and puts itself back together on the lap.
      final slides = _tusiPendulumBase + i;
      final slide = math.cos(_tau * slides * turn + theta / 2);
      return OmiDotPlacement(
        offset: OmiMarkGeometry.directionAt(theta) * (rest * slide),
        scale: 1 + 0.16 * (1 - slide.abs()),
        alpha: 0.5 + 0.5 * slide.abs(),
      );

    case OmiOrbMotion.audioBars:
      final lane = OmiMarkGeometry.laneOf(i);
      final bell =
          1 - 0.22 * ((lane / (OmiMarkGeometry.dotCount - 1) - 0.5).abs() * 2);
      final wobble =
          0.5 + 0.5 * math.sin(_tau * (turn * (2 + lane) + lane * 0.41));
      final height = (0.14 + 0.86 * lift) * bell * (0.18 + 0.82 * wobble);
      return OmiDotPlacement(
        offset: Offset(OmiMarkGeometry.laneXOf(i), 64 - 128 * height),
        scale: OmiMarkGeometry.laneDotScale * (0.85 + 0.3 * height),
        alpha: 0.58 + 0.42 * height,
      );

    case OmiOrbMotion.nestedOrbit:
      // A circle a quarter of the radius rolling without slipping around the
      // inside of the mark: the roll rate is fixed by the circumference ratio,
      // so it reads as a coin rolling rather than a dot on a stick, and four
      // whole cusps fit in a lap — the same four-fold symmetry as the mark.
      const ratio = 1 / 4;
      // Each dot is the same coin at a different moment of the same roll, so
      // the eight of them chase each other around the path instead of riding
      // it as one clump.
      final orbit = _tau * turn + theta;
      final roll = -orbit * (1 - ratio) / ratio;
      return OmiDotPlacement(
        offset:
            OmiMarkGeometry.directionAt(orbit) * (rest * (1 - ratio)) +
            OmiMarkGeometry.directionAt(roll) * (rest * ratio),
        scale: 0.9,
        alpha: 0.66 + 0.34 * (0.5 + 0.5 * math.cos(orbit - roll)),
      );

    case OmiOrbMotion.doubleCircle:
      final outer = i.isEven;
      final angle = theta + turn * _tau * (outer ? 1 : -3);
      return OmiDotPlacement(
        offset:
            OmiMarkGeometry.directionAt(angle) * (rest * (outer ? 1 : 0.44)),
        scale: outer ? 1 : 0.82,
        alpha: outer ? 0.95 : 0.68,
      );

    case OmiOrbMotion.epicycloid:
      // A circle rolling around the outside. Dot 0 leads and the rest trail it
      // by a fixed lag, so the flourish reads as one spark with a tail.
      final base = rest * 0.6;
      final roller = rest * 0.2;
      final psi = _tau * turn - i * 0.42;
      final k = (base + roller) / roller;
      return OmiDotPlacement(
        offset: Offset(
          (base + roller) * math.sin(psi) - roller * math.sin(k * psi),
          -((base + roller) * math.cos(psi) - roller * math.cos(k * psi)),
        ),
        scale: 1 + 0.3 * math.max(0, 1 - i * 0.28),
        alpha: 0.5 + 0.5 * math.max(0, 1 - i * 0.16),
      );

    case OmiOrbMotion.lissajous:
      final p = _tau * turn;
      return OmiDotPlacement(
        offset: Offset(
          74 * math.sin(2 * p + theta),
          -74 * math.sin(3 * p + theta),
        ),
        scale: 1,
        alpha: 0.66 + 0.34 * (0.5 + 0.5 * math.cos(2 * p + theta)),
      );

    case OmiOrbMotion.pendulumSwing:
      // The mark hangs from a point above itself. Each dot reads the swing a
      // few milliseconds late, which is the follow-through.
      const pivot = Offset(0, -170);
      final angle = 0.22 * math.sin(_tau * (turn - i * 0.006));
      final arm = OmiMarkGeometry.restOf(i) - pivot;
      final cos = math.cos(angle);
      final sin = math.sin(angle);
      return OmiDotPlacement(
        offset:
            pivot +
            Offset(arm.dx * cos - arm.dy * sin, arm.dx * sin + arm.dy * cos),
        scale: 1,
        alpha: 0.78 + 0.22 * (1 - angle.abs() / 0.22),
      );

    case OmiOrbMotion.successBurst:
      // Everything flies out at once and settles back with an eased return, so
      // the ring snaps home rather than drifting home.
      final eased = Curves.easeOutBack.transform(burst.clamp(0.0, 1.0));
      final scatter = burst >= 1 ? 0.0 : math.sin(burst * math.pi) * 34;
      final phase = burst >= 1 ? 0.25 : 1 - burst;
      return OmiDotPlacement(
        offset:
            OmiMarkGeometry.directionAt(theta + turn * _tau) * (rest + scatter),
        scale: 1 + phase * 0.16 + 0.1 * lift,
        alpha: (0.6 + phase * 0.4) * (burst >= 1 ? 1.0 : eased.clamp(0.0, 1.0)),
      );
  }
}

/// Travels [OmiOrbMotion.sine] makes across the chain per lap, and the phase
/// one lane lags the one before it. Whole travels per lap is what lets the
/// clock restart without the wave snapping.
const double omiSineTravelsPerLap = 2;
const double omiSineLanePhase = 0.1875;

/// Swings the slowest lane makes per lap of [OmiOrbMotion.pendulumWave]; the
/// fastest makes seven more.
const int _pendulumBase = 9;

/// Slides the slowest diameter makes per lap of [OmiOrbMotion.tusiPendulum].
const int _tusiPendulumBase = 5;

/// The whole-lap swing counts, exposed so a test can assert they stay integers
/// — the moment one is not, the motion stops resynchronising.
@visibleForTesting
List<int> get omiPendulumWaveSwings => List<int>.generate(
  OmiMarkGeometry.dotCount,
  (i) => _pendulumBase + OmiMarkGeometry.laneOf(i),
  growable: false,
);

@visibleForTesting
List<int> get omiTusiPendulumSlides => List<int>.generate(
  OmiMarkGeometry.dotCount,
  (i) => _tusiPendulumBase + i,
  growable: false,
);
