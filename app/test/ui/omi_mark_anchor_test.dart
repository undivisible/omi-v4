import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/ui/omi_cold_open.dart';
import 'package:omi/ui/omi_mark_anchor.dart';

void main() {
  testWidgets('publishes where the mark actually is', (tester) async {
    final anchor = OmiMarkAnchor();
    addTearDown(anchor.dispose);

    await tester.pumpWidget(
      OmiMarkAnchorScope(
        anchor: anchor,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: OmiMarkAnchorTarget(child: SizedBox(width: 48, height: 48)),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(anchor.value, const Rect.fromLTWH(0, 0, 48, 48));
  });

  testWidgets('reports nothing until the subtree has been laid out', (
    tester,
  ) async {
    final anchor = OmiMarkAnchor();
    addTearDown(anchor.dispose);

    expect(anchor.value, isNull);

    await tester.pumpWidget(
      OmiMarkAnchorScope(
        anchor: anchor,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: OmiMarkAnchorTarget(child: SizedBox(width: 48, height: 48)),
          ),
        ),
      ),
    );
    await tester.pump();

    // Centred in the 800x600 test window.
    expect(anchor.value, const Rect.fromLTWH(376, 276, 48, 48));
  });

  testWidgets('a mark that leaves the tree stops being a destination', (
    tester,
  ) async {
    final anchor = OmiMarkAnchor();
    addTearDown(anchor.dispose);

    await tester.pumpWidget(
      OmiMarkAnchorScope(
        anchor: anchor,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: OmiMarkAnchorTarget(child: SizedBox(width: 48, height: 48)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(anchor.value, isNotNull);

    await tester.pumpWidget(
      OmiMarkAnchorScope(
        anchor: anchor,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();

    expect(anchor.value, isNull);
  });

  testWidgets('a target with no scope above it is inert', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: OmiMarkAnchorTarget(child: SizedBox(width: 48, height: 48)),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  group('the open only flies to an anchor it can reach', () {
    const size = Size(800, 600);

    Rect? reachable(Rect? handoff) =>
        OmiColdOpenPainter.reachableAnchor(handoff, size);

    test('an anchor scrolled above the viewport is refused', () {
      // The hub greeter sits at the top of a scrollable, so opening onto a
      // chat with history reports it off the top of the screen. Flying there
      // would take the mark out of frame instead of handing it over.
      expect(reachable(const Rect.fromLTWH(376, -420, 48, 48)), isNull);
    });

    test('an anchor past the bottom or side is refused', () {
      expect(reachable(const Rect.fromLTWH(376, 900, 48, 48)), isNull);
      expect(reachable(const Rect.fromLTWH(-200, 300, 48, 48)), isNull);
      expect(reachable(const Rect.fromLTWH(1200, 300, 48, 48)), isNull);
    });

    test('an anchor on screen is accepted whole', () {
      const target = Rect.fromLTWH(376, 100, 48, 48);
      expect(reachable(target), target);
    });

    test('a degenerate or absent anchor is refused', () {
      expect(reachable(null), isNull);
      expect(reachable(Rect.zero), isNull);
    });
  });
}
