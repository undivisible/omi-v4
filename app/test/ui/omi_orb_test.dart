import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/ui/omi_cold_open.dart';
import 'package:omi/ui/omi_orb.dart';

/// A spread of lap positions, including both ends, used wherever a claim has to
/// hold for the whole cycle rather than at one convenient frame.
const _samples = [
  0.0,
  0.07,
  0.19,
  0.25,
  0.33,
  0.5,
  0.62,
  0.75,
  0.88,
  0.97,
  1.0,
];

List<OmiDotPlacement> _at(
  OmiOrbMotion motion,
  double turn, {
  double level = 0,
}) => omiOrbPlacements(motion: motion, turn: turn, level: level);

void main() {
  group('OmiThinkingPulse', () {
    test('matches site keyframe endpoints', () {
      expect(OmiThinkingPulse.at(0), (0.62, 1.0));
      expect(OmiThinkingPulse.at(0.12).$1, closeTo(1.0, 0.001));
      expect(OmiThinkingPulse.at(0.12).$2, closeTo(1.14, 0.001));
      expect(OmiThinkingPulse.at(0.70), (0.62, 1.0));
      expect(OmiThinkingPulse.at(0.99), (0.62, 1.0));
    });

    test('staggers peaks around the ring', () {
      const turn = 0.12;
      final peaks = List.generate(OmiMarkGeometry.dotCount, (i) {
        final pulse = OmiThinkingPulse.at(OmiThinkingPulse.localPhase(i, turn));
        return pulse.$1;
      });
      expect(peaks.indexOf(peaks.reduce((a, b) => a > b ? a : b)), 0);
    });
  });

  group('OmiMarkGeometry', () {
    test('lanes unroll the ring without repeating one', () {
      final lanes = List.generate(
        OmiMarkGeometry.dotCount,
        OmiMarkGeometry.laneOf,
      );
      expect(lanes.toSet().length, OmiMarkGeometry.dotCount);
      // Ring order and lane order advance together, which is what keeps a
      // travelling wave travelling in the same direction through the morph.
      for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
        final next = (i + 1) % OmiMarkGeometry.dotCount;
        expect(
          (lanes[next] - lanes[i]) % OmiMarkGeometry.dotCount,
          1,
          reason: 'dot $i and $next are not neighbours in the chain',
        );
      }
      // The chain is cut at the bottom, so due south is the far right lane.
      expect(OmiMarkGeometry.laneOf(4), OmiMarkGeometry.dotCount - 1);
      expect(
        OmiMarkGeometry.laneXOf(4),
        closeTo(OmiMarkGeometry.laneSpan, 1e-9),
      );
      expect(
        OmiMarkGeometry.laneXOf(5),
        closeTo(-OmiMarkGeometry.laneSpan, 1e-9),
      );
    });

    test('rest positions are the brand ring', () {
      expect(
        OmiMarkGeometry.restOf(0).dy,
        closeTo(-OmiMarkGeometry.axisRadius, 1e-9),
      );
      expect(
        OmiMarkGeometry.restOf(2).dx,
        closeTo(OmiMarkGeometry.axisRadius, 1e-9),
      );
      for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
        expect(
          OmiMarkGeometry.restOf(i).distance,
          closeTo(OmiMarkGeometry.radiusOf(i), 1e-9),
        );
      }
    });
  });

  group('every motion', () {
    test('places eight finite, drawable dots at every point in the lap', () {
      for (final motion in OmiOrbMotion.values) {
        for (final turn in _samples) {
          for (final level in const [0.0, 0.4, 1.0]) {
            final dots = _at(motion, turn, level: level);
            expect(dots, hasLength(OmiMarkGeometry.dotCount));
            for (final dot in dots) {
              final where = '$motion @ turn $turn level $level';
              expect(dot.offset.dx.isFinite, isTrue, reason: where);
              expect(dot.offset.dy.isFinite, isTrue, reason: where);
              expect(dot.scale, greaterThan(0), reason: where);
              expect(dot.scale, lessThan(2), reason: where);
              expect(dot.alpha, inInclusiveRange(0, 1), reason: where);
              // Nothing may wander outside the mark's own canvas, or a 22px
              // orb would clip its dots against the widget's box.
              expect(
                dot.offset.distance,
                lessThanOrEqualTo(OmiMarkGeometry.canvas / 2),
                reason: where,
              );
            }
          }
        }
      }
    });

    test('is continuous across the lap boundary', () {
      for (final motion in OmiOrbMotion.values) {
        final end = _at(motion, 0.999);
        final start = _at(motion, 0);
        for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
          expect(
            (end[i].offset - start[i].offset).distance,
            lessThan(6),
            reason: '$motion jumps at the lap mark on dot $i',
          );
        }
      }
    });
  });

  group('mark', () {
    test('keeps the brand radii, breathing by a couple of units at most', () {
      for (final turn in _samples) {
        final dots = _at(OmiOrbMotion.mark, turn);
        for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
          expect(
            dots[i].offset.distance - OmiMarkGeometry.radiusOf(i),
            inInclusiveRange(-1e-9, 2.2 + 1e-9),
          );
        }
      }
    });

    test('turns exactly one lap', () {
      // A quarter lap puts due north where due east was.
      final quarter = _at(OmiOrbMotion.mark, 0.25);
      expect(quarter[0].offset.dx, greaterThan(0));
      expect(quarter[0].offset.dy.abs(), lessThan(1));
    });
  });

  group('tusi couple', () {
    test('every dot stays on its own diameter through the centre', () {
      for (final motion in const [
        OmiOrbMotion.tusi,
        OmiOrbMotion.tusiPendulum,
      ]) {
        for (final turn in _samples) {
          final dots = _at(motion, turn);
          for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
            final line = OmiMarkGeometry.directionAt(
              OmiMarkGeometry.angleOf(i),
            );
            final at = dots[i].offset;
            // Zero cross product with the rest direction: the point is on the
            // line through the centre, which is the whole claim of the couple.
            expect(
              at.dx * line.dy - at.dy * line.dx,
              closeTo(0, 1e-9),
              reason: '$motion dot $i left its diameter at turn $turn',
            );
            expect(
              at.distance,
              lessThanOrEqualTo(OmiMarkGeometry.radiusOf(i) + 1e-9),
              reason: '$motion dot $i overran its diameter at turn $turn',
            );
          }
        }
      }
    });

    test('the plain couple sweeps a full diameter each half lap', () {
      // Dot 0 has no phase offset, so it runs rest -> centre -> opposite.
      expect(
        _at(OmiOrbMotion.tusi, 0)[0].offset.dy,
        closeTo(-OmiMarkGeometry.axisRadius, 1e-9),
      );
      expect(
        _at(OmiOrbMotion.tusi, 0.125)[0].offset.distance,
        closeTo(0, 1e-9),
      );
      expect(
        _at(OmiOrbMotion.tusi, 0.25)[0].offset.dy,
        closeTo(OmiMarkGeometry.axisRadius, 1e-9),
      );
    });

    test('the detuned couple resynchronises on the lap', () {
      // Whole slide counts are the mechanism: one non-integer and the lattice
      // never comes back together, so the cold open would end mid-bloom.
      expect(omiTusiPendulumSlides.every((s) => s > 0), isTrue);
      expect(omiTusiPendulumSlides.toSet().length, OmiMarkGeometry.dotCount);
      final start = _at(OmiOrbMotion.tusiPendulum, 0);
      final end = _at(OmiOrbMotion.tusiPendulum, 1);
      for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
        expect((end[i].offset - start[i].offset).distance, closeTo(0, 1e-9));
      }
    });

    test('desynchronises in between, or it would just be a spin', () {
      // Somewhere in the lap the lattice is fully torn: one dot out at the rim
      // while another is all but on the centre.
      final widest = List.generate(200, (s) {
        final dots = _at(OmiOrbMotion.tusiPendulum, s / 200);
        final radii = [
          for (var i = 0; i < OmiMarkGeometry.dotCount; i++)
            dots[i].offset.distance / OmiMarkGeometry.radiusOf(i),
        ];
        return radii.reduce(math.max) - radii.reduce(math.min);
      }).reduce(math.max);
      expect(widest, greaterThan(0.9));
    });
  });

  group('pendulum wave', () {
    test('is a flat line at the lap mark and scattered in between', () {
      final line = _at(OmiOrbMotion.pendulumWave, 0);
      for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
        expect(line[i].offset.dy, closeTo(OmiMarkGeometry.laneYOf(i), 1e-9));
      }
      final spread = _at(
        OmiOrbMotion.pendulumWave,
        0.29,
      ).map((d) => d.offset.dy).toList();
      expect(
        spread.reduce(math.max) - spread.reduce(math.min),
        greaterThan(20),
      );
    });

    test('gives every lane its own whole number of swings', () {
      expect(omiPendulumWaveSwings.toSet().length, OmiMarkGeometry.dotCount);
      expect(omiPendulumWaveSwings.reduce(math.min), greaterThan(0));
    });

    test('holds the lanes in x so only the swing reads', () {
      for (final turn in _samples) {
        final dots = _at(OmiOrbMotion.pendulumWave, turn);
        for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
          expect(dots[i].offset.dx, closeTo(OmiMarkGeometry.laneXOf(i), 1e-9));
        }
      }
    });
  });

  group('sine', () {
    test('is still the ring in silence', () {
      for (final turn in _samples) {
        final dots = _at(OmiOrbMotion.sine, turn);
        for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
          expect(
            (dots[i].offset.distance - OmiMarkGeometry.radiusOf(i)).abs(),
            lessThanOrEqualTo(3.0001),
            reason: 'dot $i left the ring at level 0',
          );
        }
      }
    });

    test('flattens onto the chain and fits a sine when spoken into', () {
      final dots = _at(OmiOrbMotion.sine, 0.31, level: 1);
      for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
        expect(dots[i].offset.dx, closeTo(OmiMarkGeometry.laneXOf(i), 0.6));
      }
      // Read the heights back in lane order and check they are the sine the
      // layout claims to be, not eight independent wobbles.
      const amplitude = 12 + 60.0;
      for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
        final phase =
            2 *
            math.pi *
            (0.31 * omiSineTravelsPerLap -
                OmiMarkGeometry.laneOf(i) * omiSineLanePhase);
        expect(
          dots[i].offset.dy - OmiMarkGeometry.laneYOf(i),
          closeTo(-amplitude * math.sin(phase), 1.2),
        );
      }
    });

    test('travels one way along the chain', () {
      // Whatever lane 0 is doing now, lane 1 does one phase step later — the
      // wave runs left to right rather than standing still or running back.
      double heightOfLane(int lane, double turn) {
        final i = List.generate(
          OmiMarkGeometry.dotCount,
          (i) => i,
        ).firstWhere((i) => OmiMarkGeometry.laneOf(i) == lane);
        return _at(OmiOrbMotion.sine, turn, level: 1)[i].offset.dy -
            OmiMarkGeometry.laneYOf(i);
      }

      const step = omiSineLanePhase / omiSineTravelsPerLap;
      expect(heightOfLane(1, 0.2 + step), closeTo(heightOfLane(0, 0.2), 0.01));
    });
  });

  group('double circle', () {
    test('holds the axes out and pulls the diagonals in, counter-turning', () {
      for (final turn in _samples) {
        final dots = _at(OmiOrbMotion.doubleCircle, turn);
        for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
          expect(
            dots[i].offset.distance,
            closeTo(OmiMarkGeometry.radiusOf(i) * (i.isEven ? 1 : 0.44), 1e-9),
          );
        }
      }
      // Opposite signs on the swept area is what makes it read as two rings.
      final a = _at(OmiOrbMotion.doubleCircle, 0);
      final b = _at(OmiOrbMotion.doubleCircle, 0.02);
      double sweep(int i) =>
          a[i].offset.dx * b[i].offset.dy - a[i].offset.dy * b[i].offset.dx;
      expect(sweep(0).sign, isNot(sweep(1).sign));
    });
  });

  group('gather', () {
    test('collapses toward the centre and springs back past rest', () {
      final radii = List.generate(
        OmiMarkGeometry.dotCount,
        (i) => List.generate(
          101,
          (s) => _at(OmiOrbMotion.gather, s / 100)[i].offset.distance,
        ),
      );
      for (var i = 0; i < OmiMarkGeometry.dotCount; i++) {
        expect(
          radii[i].reduce(math.min),
          lessThan(OmiMarkGeometry.radiusOf(i) * 0.25),
        );
        expect(
          radii[i].reduce(math.max),
          greaterThan(OmiMarkGeometry.radiusOf(i)),
        );
      }
    });
  });

  group('successBurst', () {
    test('scatters mid-burst and sits on the ring once it is over', () {
      final mid = omiOrbPlacements(
        motion: OmiOrbMotion.successBurst,
        turn: 0,
        burst: 0.5,
      );
      expect(mid[0].offset.distance, greaterThan(OmiMarkGeometry.axisRadius));
      final done = omiOrbPlacements(motion: OmiOrbMotion.successBurst, turn: 0);
      expect(
        done[0].offset.distance,
        closeTo(OmiMarkGeometry.axisRadius, 1e-9),
      );
    });
  });

  group('state mapping', () {
    test('sends each product state to its choreography', () {
      expect(omiMotionForState(OmiOrbState.idle), OmiOrbMotion.mark);
      expect(omiMotionForState(OmiOrbState.thinking), OmiOrbMotion.pulse);
      expect(omiMotionForState(OmiOrbState.listening), OmiOrbMotion.sine);
      expect(omiMotionForState(OmiOrbState.success), OmiOrbMotion.successBurst);
    });
  });

  group('OmiDotPlacement', () {
    test('lerps every channel', () {
      const a = OmiDotPlacement(offset: Offset.zero, scale: 1, alpha: 0);
      const b = OmiDotPlacement(offset: Offset(10, 20), scale: 2, alpha: 1);
      final half = OmiDotPlacement.lerp(a, b, 0.5);
      expect(half.offset, const Offset(5, 10));
      expect(half.scale, 1.5);
      expect(half.alpha, 0.5);
    });
  });

  group('OmiActivityOrb', () {
    testWidgets('settles while held still, whatever motion it is given', (
      tester,
    ) async {
      for (final motion in OmiOrbMotion.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(child: OmiActivityOrb(size: 46, motion: motion)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(OmiActivityOrb), findsOneWidget);
      }
    });

    testWidgets('takes a motion change without throwing', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Center(child: OmiActivityOrb(size: 46))),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: OmiActivityOrb(
              size: 46,
              state: OmiOrbState.listening,
              amplitude: 0.8,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('OmiColdOpen', () {
    testWidgets('hands over immediately when motion is held still', (
      tester,
    ) async {
      var done = 0;
      await tester.pumpWidget(
        MaterialApp(home: OmiColdOpen(onDone: () => done++)),
      );
      await tester.pumpAndSettle();
      expect(done, 1);
    });

    testWidgets('runs the whole timeline once when motion is allowed', (
      tester,
    ) async {
      // The static path short-circuits on the first frame, so it never touches
      // the converge, the showcase or the handover.
      debugOmiOrbStatic = false;
      addTearDown(() => debugOmiOrbStatic = true);
      var done = 0;
      await tester.pumpWidget(
        MaterialApp(home: OmiColdOpen(onDone: () => done++)),
      );
      await tester.pump();
      expect(done, 0);
      await tester.pump(OmiColdOpen.duration ~/ 2);
      expect(done, 0);
      await tester.pump(OmiColdOpen.duration);
      expect(done, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hands over only once when also tapped', (tester) async {
      var done = 0;
      await tester.pumpWidget(
        MaterialApp(home: OmiColdOpen(onDone: () => done++)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(OmiColdOpen));
      await tester.pumpAndSettle();
      expect(done, 1);
    });
  });
}
