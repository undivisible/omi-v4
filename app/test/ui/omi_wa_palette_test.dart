import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/ui/omi_wa_palette.dart';

void main() {
  group('OmiWaPalette', () {
    test('every gradient quotes a real plate with named colours', () {
      expect(OmiWaPalette.all, isNotEmpty);
      final plates = <int>{};
      for (final gradient in OmiWaPalette.all) {
        expect(
          gradient.stops.length,
          gradient.names.length,
          reason: '${gradient.name} has a colour without a name',
        );
        expect(gradient.stops.length, greaterThanOrEqualTo(2));
        // 348 plates in the 配色事典; anything outside that is a typo, not a
        // citation.
        expect(gradient.plate, inInclusiveRange(1, 348));
        expect(plates.add(gradient.plate), isTrue, reason: 'duplicate plate');
        expect(OmiWaPalette.byPlate(gradient.plate), same(gradient));
      }
    });

    test('every stop is opaque, so a veil sets its own alpha', () {
      for (final gradient in OmiWaPalette.all) {
        for (final color in gradient.stops) {
          expect(
            color.a,
            1.0,
            reason: '${gradient.name} has a translucent stop',
          );
        }
      }
    });

    test('bokashi runs top to bottom and keeps the plate order', () {
      final gradient = OmiWaPalette.dawn.bokashi();
      expect(gradient.begin, Alignment.topCenter);
      expect(gradient.end, Alignment.bottomCenter);
      expect(gradient.colors, OmiWaPalette.dawn.stops);
    });

    test('veil holds every stop to the same alpha', () {
      final veil = OmiWaPalette.indigo.veil(opacity: 0.2);
      expect(veil.colors, hasLength(OmiWaPalette.indigo.stops.length));
      for (final color in veil.colors) {
        expect(color.a, closeTo(0.2, 0.005));
      }
    });

    test('ink contrasts with the colour type actually lands on', () {
      // Every plate here ends dark, so type over a full bokashi is cream.
      for (final gradient in OmiWaPalette.all) {
        final onLast = ThemeData.estimateBrightnessForColor(
          gradient.stops.last,
        );
        expect(
          gradient.ink,
          onLast == Brightness.dark
              ? const Color(0xfffffcec)
              : const Color(0xff171716),
          reason: gradient.name,
        );
      }
    });
  });
}
