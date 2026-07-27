import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
