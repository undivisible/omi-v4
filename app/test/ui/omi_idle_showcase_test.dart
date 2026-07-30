import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/ui/omi_idle_showcase.dart';
import 'package:omi/ui/omi_orb.dart';

void main() {
  const settleAfter = Duration(seconds: 10);
  const restBetween = Duration(seconds: 30);
  const lap = Duration(milliseconds: 5200);

  // The package harness holds the mark still so `pumpAndSettle` can return.
  // This suite is about when the showcase runs, so it needs the real clock.
  setUp(() {
    debugOmiOrbStatic = false;
    addTearDown(() => debugOmiOrbStatic = true);
  });

  OmiOrbMotion? motionOf(WidgetTester tester) =>
      tester.widget<OmiActivityOrb>(find.byType(OmiActivityOrb)).motion;

  Future<void> pumpShowcase(WidgetTester tester) => tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: OmiIdleShowcase(
            settleAfter: settleAfter,
            restBetween: restBetween,
            lap: lap,
          ),
        ),
      ),
    ),
  );

  testWidgets('rests until the screen has been left alone', (tester) async {
    await pumpShowcase(tester);

    expect(motionOf(tester), isNull);
    await tester.pump(settleAfter - const Duration(seconds: 1));
    expect(motionOf(tester), isNull);
  });

  testWidgets('performs one lap and then settles back to rest', (tester) async {
    await pumpShowcase(tester);

    await tester.pump(settleAfter);
    expect(motionOf(tester), OmiIdleShowcase.rotation.first);

    // Still the same motion for the whole lap: it never cuts to another one
    // mid-performance.
    await tester.pump(lap - const Duration(milliseconds: 100));
    expect(motionOf(tester), OmiIdleShowcase.rotation.first);

    await tester.pump(const Duration(milliseconds: 100));
    expect(motionOf(tester), isNull);

    // And it stays at rest through a gap far longer than a lap.
    await tester.pump(restBetween - const Duration(seconds: 1));
    expect(motionOf(tester), isNull);
  });

  testWidgets('the next performance uses the next motion', (tester) async {
    await pumpShowcase(tester);

    await tester.pump(settleAfter);
    await tester.pump(lap);
    await tester.pump(restBetween);

    expect(motionOf(tester), OmiIdleShowcase.rotation[1]);

    await tester.pump(lap);
    await tester.pump(restBetween);
    expect(motionOf(tester), OmiIdleShowcase.rotation.first);
  });

  testWidgets('a pointer stops the performance and restarts the wait', (
    tester,
  ) async {
    await pumpShowcase(tester);
    await tester.pump(settleAfter);
    expect(motionOf(tester), isNotNull);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(OmiActivityOrb)));
    await tester.pump();

    expect(motionOf(tester), isNull);

    // The full settle has to elapse again, not the remainder of the lap.
    await tester.pump(settleAfter - const Duration(seconds: 1));
    expect(motionOf(tester), isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(motionOf(tester), isNotNull);
  });

  testWidgets('a working state outranks the showcase', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: OmiIdleShowcase(
              settleAfter: settleAfter,
              restBetween: restBetween,
              lap: lap,
              state: OmiOrbState.thinking,
            ),
          ),
        ),
      ),
    );

    await tester.pump(settleAfter);
    // The state picks the motion, so the showcase must not be overriding it.
    expect(motionOf(tester), isNull);
    await tester.pump(lap);
  });
}
