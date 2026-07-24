import 'package:flutter_test/flutter_test.dart';
import 'package:omi/demo/demo_guide.dart';
import 'package:omi/demo/demo_model.dart';
import 'package:omi/demo/demo_native_hub.dart';
import 'package:omi/demo/demo_prompt_bus.dart';
import 'package:omi/native/native_hub.dart';

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
