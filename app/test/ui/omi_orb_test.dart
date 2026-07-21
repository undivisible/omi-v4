import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/ui/omi_orb.dart';

void main() {
  testWidgets('morphs from idle mark into real activity states', (
    tester,
  ) async {
    var state = OmiOrbState.idle;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return OmiActivityOrb(state: state);
          },
        ),
      ),
    );

    expect(find.bySemanticsLabel('Omi idle'), findsOneWidget);
    update(() => state = OmiOrbState.listening);
    await tester.pump(const Duration(milliseconds: 320));
    expect(find.bySemanticsLabel('Omi listening'), findsOneWidget);
    update(() => state = OmiOrbState.thinking);
    await tester.pump();
    expect(find.bySemanticsLabel('Omi thinking'), findsOneWidget);
  });

  testWidgets('reduced motion settles without a repeating ticker', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: OmiActivityOrb(state: OmiOrbState.speaking),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Omi speaking'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  test('painter renders every living state within its fixed point budget', () {
    for (final state in OmiOrbState.values) {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      OmiOrbPainter(
        state: state,
        phase: .5,
        morph: 1,
      ).paint(canvas, const Size.square(46));
      recorder.endRecording();
    }
  });
}
