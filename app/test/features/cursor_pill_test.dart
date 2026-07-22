import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/features/cursor_pill.dart';
import 'package:omi/features/cursor_pill_controller.dart';
import 'package:omi/features/voice_intents.dart';
import 'package:omi/native/generated/signals/signals.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  test('double-shift walks hidden → input → listening → hidden', () async {
    final harness = _Harness();
    final controller = harness.controller();

    await controller.doubleShift();
    expect(controller.state, CursorPillState.input);
    harness.advance(const Duration(seconds: 1));
    await controller.doubleShift();
    expect(controller.state, CursorPillState.listening);
    expect(harness.voiceStarts, 1);
    harness.advance(const Duration(seconds: 1));
    await controller.doubleShift();
    expect(controller.state, CursorPillState.hidden);
    expect(harness.voiceStops, 1);

    controller.dispose();
    await harness.close();
  });

  test('double-shift within the debounce window is ignored', () async {
    final harness = _Harness();
    final controller = harness.controller();

    await controller.doubleShift();
    expect(controller.state, CursorPillState.input);
    harness.advance(const Duration(milliseconds: 300));
    await controller.doubleShift();
    expect(controller.state, CursorPillState.input);
    expect(harness.voiceStarts, 0);
    harness.advance(const Duration(milliseconds: 600));
    await controller.doubleShift();
    expect(controller.state, CursorPillState.listening);

    controller.dispose();
    await harness.close();
  });

  test('escape dismisses from input and listening', () async {
    final harness = _Harness();
    final controller = harness.controller();

    await controller.doubleShift();
    await controller.dismiss();
    expect(controller.state, CursorPillState.hidden);

    harness.advance(const Duration(seconds: 1));
    await controller.doubleShift();
    harness.advance(const Duration(seconds: 1));
    await controller.doubleShift();
    expect(controller.state, CursorPillState.listening);
    await controller.dismiss();
    expect(controller.state, CursorPillState.hidden);
    expect(harness.voiceCancels, 1);

    controller.dispose();
    await harness.close();
  });

  test('stop transcript with a currents phrase opens the hub', () async {
    final harness = _Harness(stopTranscript: 'Show me my currents please');
    final controller = harness.controller();

    await controller.doubleShift();
    harness.advance(const Duration(seconds: 1));
    await controller.doubleShift();
    harness.advance(const Duration(seconds: 1));
    await controller.doubleShift();

    expect(harness.hubOpens, 1);
    expect(controller.state, CursorPillState.hidden);
    controller.dispose();
    await harness.close();
  });

  test('intent matcher accepts currents and tasks phrases only', () {
    expect(matchesShowHubIntent('Show me my currents'), isTrue);
    expect(matchesShowHubIntent('show me my tasks.'), isTrue);
    expect(matchesShowHubIntent('open the current'), isTrue);
    expect(matchesShowHubIntent('write an email to my boss'), isFalse);
  });

  testWidgets('summon renders up to three suggestions from memory search', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CursorPill(controller: controller)),
      ),
    );

    await controller.summon();
    expect(harness.hub.searches, hasLength(1));
    harness.hub.add(
      NativeEventMemorySearchResults(
        value: MemorySearchResults(
          requestId: harness.hub.searches.single.requestId,
          query: CursorPillController.suggestionQuery,
          items: const [
            MemorySearchItem(
              kind: 'claim',
              id: 'a',
              excerpt: 'Write that email to your boss at boss@example.com',
              relevanceBasisPoints: 9000,
              evidenceIds: [],
            ),
            MemorySearchItem(
              kind: 'claim',
              id: 'b',
              excerpt: 'Finish the quarterly report',
              relevanceBasisPoints: 8000,
              evidenceIds: [],
            ),
            MemorySearchItem(
              kind: 'claim',
              id: 'c',
              excerpt: 'Call the dentist back',
              relevanceBasisPoints: 7000,
              evidenceIds: [],
            ),
            MemorySearchItem(
              kind: 'claim',
              id: 'd',
              excerpt: 'A fourth low-relevance item',
              relevanceBasisPoints: 100,
              evidenceIds: [],
            ),
          ],
          gaps: [],
        ),
      ),
    );
    await tester.pump();

    expect(controller.suggestions, hasLength(3));
    expect(
      find.textContaining('Write that email to your boss'),
      findsOneWidget,
    );
    expect(find.textContaining('Finish the quarterly report'), findsOneWidget);
    expect(find.textContaining('fourth low-relevance'), findsNothing);
    expect(
      controller.suggestions.first.link,
      Uri(scheme: 'mailto', path: 'boss@example.com'),
    );
    expect(controller.suggestions[1].link, isNull);

    await tester.tap(find.textContaining('Write that email to your boss'));
    await tester.pump();
    expect(harness.launchedLinks.single.scheme, 'mailto');
    expect(controller.state, CursorPillState.hidden);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await harness.close();
  });

  testWidgets('empty memory shows the ask-me-anything placeholder', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CursorPill(controller: controller)),
      ),
    );

    await controller.summon();
    harness.hub.add(
      NativeEventMemorySearchResults(
        value: MemorySearchResults(
          requestId: harness.hub.searches.single.requestId,
          query: CursorPillController.suggestionQuery,
          items: const [],
          gaps: [],
        ),
      ),
    );
    await tester.pump();

    expect(controller.suggestions, isEmpty);
    expect(find.text('Ask me anything…'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await harness.close();
  });

  testWidgets('second double-shift switches the pill to listening', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CursorPill(controller: controller)),
      ),
    );

    await controller.doubleShift();
    await tester.pump();
    expect(find.byKey(const Key('cursor_pill_input')), findsOneWidget);

    harness.advance(const Duration(seconds: 1));
    await controller.doubleShift();
    await tester.pump();

    expect(find.byKey(const Key('cursor_pill_listening')), findsOneWidget);
    expect(find.byKey(const Key('cursor_pill_waveform')), findsOneWidget);
    expect(find.byKey(const Key('cursor_pill_input')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await harness.close();
  });

  testWidgets('typed submit routes to the prompt pipeline', (tester) async {
    final harness = _Harness();
    final controller = harness.controller();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CursorPill(controller: controller)),
      ),
    );

    await controller.summon();
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('cursor_pill_input')),
      'Draft a summary of today',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(harness.prompts, ['Draft a summary of today']);
    expect(controller.state, CursorPillState.hidden);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await harness.close();
  });

  test('voice start errors map to specific actionable messages', () {
    String messageFor(VoiceStartFailure failure) =>
        CursorPillController.voiceStartErrorMessage(
          VoiceStartException(failure, 'internal detail'),
        );
    expect(
      messageFor(VoiceStartFailure.microphonePermission),
      contains('System Settings'),
    );
    expect(messageFor(VoiceStartFailure.signedOut), contains('sign in'));
    expect(
      messageFor(VoiceStartFailure.backendNotConfigured),
      contains('No voice service is set up'),
    );
    expect(messageFor(VoiceStartFailure.network), contains('connection'));
    expect(
      messageFor(VoiceStartFailure.unsupportedPlatform),
      contains('platform'),
    );
    expect(
      CursorPillController.voiceStartErrorMessage(StateError('anything')),
      'I couldn’t start listening. Check the microphone.',
    );
  });

  test(
    'failed voice start surfaces the mapped error and returns to input',
    () async {
      final harness = _Harness(
        startVoiceError: VoiceStartException(
          VoiceStartFailure.microphonePermission,
          'Microphone permission is required for desktop voice.',
        ),
      );
      final controller = harness.controller();

      await controller.doubleShift();
      harness.advance(const Duration(seconds: 1));
      await controller.doubleShift();

      expect(controller.state, CursorPillState.input);
      expect(controller.error, contains('Privacy & Security'));

      controller.dispose();
      await harness.close();
    },
  );

  testWidgets('pill renders as a compact liquid-glass surface', (tester) async {
    final harness = _Harness();
    final controller = harness.controller();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CursorPill(controller: controller)),
      ),
    );

    await controller.summon();
    await tester.pump();

    expect(pillHeight, 36.0);
    final glass = find.byType(LiquidGlass);
    expect(glass, findsOneWidget);
    expect(
      find.descendant(of: glass, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    final box = tester.getSize(glass);
    expect(box.height, pillHeight);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await harness.close();
  });
}

final class _Harness {
  _Harness({this.stopTranscript = '', this.startVoiceError});

  final hub = _FakeNativeHub();
  final level = ValueNotifier<double>(0);
  final prompts = <String>[];
  final launchedLinks = <Uri>[];
  final String stopTranscript;
  final Object? startVoiceError;
  int voiceStarts = 0;
  int voiceStops = 0;
  int voiceCancels = 0;
  int hubOpens = 0;
  DateTime now = DateTime.utc(2026, 7, 22);

  void advance(Duration duration) => now = now.add(duration);

  CursorPillController controller() => CursorPillController(
    hub: hub,
    events: hub.events,
    startVoice: () async {
      if (startVoiceError case final error?) throw error;
      voiceStarts += 1;
    },
    stopVoice: () async {
      voiceStops += 1;
      return stopTranscript;
    },
    cancelVoice: () async => voiceCancels += 1,
    sendPrompt: (text) async => prompts.add(text),
    level: level,
    openHub: () => hubOpens += 1,
    launchLink: (link) async {
      launchedLinks.add(link);
      return true;
    },
    now: () => now,
  );

  Future<void> close() => hub.close();
}

final class _FakeNativeHub implements NativeHub {
  final _events = StreamController<NativeEvent>.broadcast(sync: true);
  final searches = <({String requestId, String query})>[];

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  void add(NativeEvent event) => _events.add(event);

  Future<void> close() => _events.close();

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  }) => searches.add((requestId: requestId, query: query));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
