import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/demo/demo_app.dart';
import 'package:omi/demo/demo_guide.dart';
import 'package:omi/demo/demo_model.dart';
import 'package:omi/demo/demo_native_hub.dart';
import 'package:omi/demo/demo_prompt_bus.dart';
import 'package:omi/demo/demo_seed.dart';
import 'package:omi/demo/demo_tour.dart';
import 'package:omi/main.dart';
import 'package:omi/native/native_hub.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the tour resolves its own chips and the visitor\'s own words', () {
    final tour = DemoTour();
    expect(tour.match('What are currents?')?.id, 'currents');
    expect(tour.match('tell me about the pendant')?.id, 'pendant');
    expect(tour.match('how do you know that')?.id, 'memory');
    expect(tour.match('what is the weather'), isNull);
  });

  test('taking a step does not move the visitor off the chat', () {
    final tour = DemoTour();
    final step = DemoTour.steps.firstWhere((step) => step.id == 'currents');
    tour.enter(step);
    expect(tour.visited, contains('currents'));
    expect(tour.lastStep, same(step));
    // Entering is not showing: the answer streams into the chat first.
    expect(tour.surface.value, DemoSurface.hub);
    tour.show(step.surface);
    expect(tour.surface.value, DemoSurface.currents);
  });

  test('every step carries both a scripted answer and model grounding', () {
    for (final step in DemoTour.steps) {
      expect(step.reply.trim(), isNotEmpty, reason: step.id);
      expect(step.grounding.trim(), isNotEmpty, reason: step.id);
      expect(step.chip.trim(), isNotEmpty, reason: step.id);
    }
  });

  test('with no model, a tour question is answered from its step', () async {
    // No browser here, so [DemoModel] stays on the scripted tier — which is
    // exactly the tier most visitors get.
    expect(DemoModel.instance.tier, DemoModelTier.scripted);
    final hub = DemoNativeHub();
    final buffer = StringBuffer();
    final done = hub.events
        .where(
          (event) =>
              event is NativeEventAssistantDelta &&
              event.value.requestId == 'tour-1',
        )
        .cast<NativeEventAssistantDelta>()
        .map((event) {
          buffer.write(event.value.text);
          return event.value.finalSegment;
        })
        .firstWhere((last) => last);
    hub.sendMessage(requestId: 'tour-1', text: 'What are currents?');
    await done;
    final step = DemoTour.steps.firstWhere((step) => step.id == 'currents');
    expect(buffer.toString(), step.reply);
    hub.dispose();
  });

  testWidgets(
    'tapping the next chip advances the panel through every step, hosted '
    'the way the demo hosts it (in the navigator overlay, above the routes)',
    (tester) async {
      // The panel rides the navigator's overlay via [DemoTourOverlay], pinned
      // above the routes. The regression this guards: the tour advances
      // internally but the panel never reflects it, so the visitor is stuck on
      // the first chip — which is what happened when the panel was hosted above
      // the navigator by `MaterialApp.builder` and could not repaint itself.
      SharedPreferences.setMockInitialValues(demoPreferences());
      DemoTour.instance.restart();
      addTearDown(DemoTour.instance.restart);

      final services = await createDemoServices();
      addTearDown(services.dispose);
      final navigator = GlobalKey<NavigatorState>();
      final tour = DemoTourOverlay(services: services, navigator: navigator);
      await tester.pumpWidget(
        OmiApp(
          services: services,
          onboardingCompletionStore: demoOnboardingCompletion(),
          platformOverride: TargetPlatform.macOS,
          navigatorKey: navigator,
          navigatorObservers: [tour.observer],
          overlayBuilder: (context, child) => DemoBanner(
            services: services,
            navigator: navigator,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // The scripted tier answers here — there is no browser model in a test.
      expect(
        find.text('Scripted preview — no model is running'),
        findsOneWidget,
      );

      final total = DemoTour.steps.length;
      for (var i = 0; i < total; i++) {
        final step = DemoTour.steps[i];
        // The next chip shows this step, and the counter is where we left it.
        expect(
          find.text(step.chip),
          findsOneWidget,
          reason: 'chip for ${step.id} at position $i',
        );
        expect(find.text('$i of $total'), findsOneWidget, reason: step.id);

        await tester.tap(find.byKey(const Key('demo_tour_next')));
        await tester.pump();
        await tester.pump();

        // The panel reflects the advance: the count moved on.
        expect(
          find.text('${i + 1} of $total'),
          findsOneWidget,
          reason: 'after taking ${step.id}',
        );
      }

      // The final step landed: no next chip, and the tour reads as finished.
      expect(find.byKey(const Key('demo_tour_next')), findsNothing);
      expect(find.textContaining('That is the whole tour'), findsOneWidget);
      expect(DemoTour.instance.finished, isTrue);
    },
  );

  test('the prompt bus only speaks to an attached composer', () {
    final bus = DemoPromptBus();
    final sent = <String>[];
    expect(bus.attached, isFalse);
    bus.send('ignored');
    void handler(String prompt) => sent.add(prompt);
    bus.attach(handler);
    expect(bus.attached, isTrue);
    bus.send('What is Omi?');
    bus.detach(handler);
    bus.send('ignored too');
    expect(sent, ['What is Omi?']);
    expect(bus.attached, isFalse);
  });
}
