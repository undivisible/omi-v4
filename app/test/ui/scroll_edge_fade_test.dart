import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/ui/scroll_edge_fade.dart';

double _opacity(WidgetTester tester, String key) => tester
    .widget<AnimatedOpacity>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .opacity;

void main() {
  Future<void> pumpList(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: ScrollEdgeFade(
              child: ListView(
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 40, child: Text('row $i')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('resting at the top shows only the bottom fade', (tester) async {
    await pumpList(tester);
    expect(_opacity(tester, 'scroll_edge_fade_top'), 0);
    expect(_opacity(tester, 'scroll_edge_fade_bottom'), 1);
  });

  testWidgets('scrolling into the middle shows both fades', (tester) async {
    await pumpList(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(_opacity(tester, 'scroll_edge_fade_top'), 1);
    expect(_opacity(tester, 'scroll_edge_fade_bottom'), 1);
  });

  testWidgets('resting at the bottom shows only the top fade', (tester) async {
    await pumpList(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(_opacity(tester, 'scroll_edge_fade_top'), 1);
    expect(_opacity(tester, 'scroll_edge_fade_bottom'), 0);
  });

  testWidgets('content shorter than the viewport shows no fades', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: ScrollEdgeFade(
              child: SingleChildScrollView(child: SizedBox(height: 40)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_opacity(tester, 'scroll_edge_fade_top'), 0);
    expect(_opacity(tester, 'scroll_edge_fade_bottom'), 0);
  });
}
