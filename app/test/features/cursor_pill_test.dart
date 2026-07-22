import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/currents/currents.dart';
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
    expect(messageFor(VoiceStartFailure.signedOut), 'internal detail');
    expect(
      CursorPillController.voiceStartErrorMessage(
        VoiceStartException(VoiceStartFailure.signedOut, ''),
      ),
      contains('sign in'),
    );
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

  testWidgets('hidden pill renders nothing at all', (tester) async {
    final harness = _Harness();
    final controller = harness.controller();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CursorPill(controller: controller)),
      ),
    );

    expect(controller.state, CursorPillState.hidden);
    expect(find.byKey(const Key('cursor_pill')), findsNothing);
    expect(find.byType(LiquidGlass), findsNothing);
    expect(find.byType(TextField), findsNothing);

    await controller.summon();
    await tester.pump();
    expect(find.byKey(const Key('cursor_pill')), findsOneWidget);

    await controller.dismiss();
    await tester.pump();
    expect(find.byKey(const Key('cursor_pill')), findsNothing);
    expect(find.byType(LiquidGlass), findsNothing);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await harness.close();
  });

  test('a live session dying while listening closes the pill', () async {
    final harness = _Harness(stopTranscript: 'show me my currents');
    final controller = harness.controller();

    await controller.doubleShift();
    harness.advance(const Duration(seconds: 1));
    await controller.doubleShift();
    expect(controller.state, CursorPillState.listening);

    harness.hub.add(
      NativeEventLiveVoiceState(
        value: LiveVoiceState(
          liveStreamId: 'live-1',
          state: LiveVoicePhase.failed,
          detail: 'connection lost',
        ),
      ),
    );
    await pumpEventQueue();

    expect(controller.state, CursorPillState.hidden);
    expect(harness.voiceStops, 1);
    expect(harness.hubOpens, 1);

    controller.dispose();
    await harness.close();
  });

  testWidgets('waveform bars are center-weighted and react to the level', (
    tester,
  ) async {
    final level = ValueNotifier<double>(0);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(body: PillWaveform(level: level)),
        ),
      ),
    );

    expect(PillWaveform.barProfile, [0.55, 0.8, 1.0, 0.8, 0.55]);
    CustomPaint paintOf() => tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(PillWaveform),
        matching: find.byType(CustomPaint),
      ),
    );
    expect((paintOf().painter! as PillWaveformPainter).level, 0);

    level.value = 0.9;
    await tester.pump();
    expect((paintOf().painter! as PillWaveformPainter).level, 0.9);

    await tester.pumpWidget(const SizedBox());
    level.dispose();
  });

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
    // The glass material is native (below the Flutter view); the widget
    // itself must not paint a fake blur.
    expect(
      find.descendant(of: glass, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    final box = tester.getSize(glass);
    expect(box.height, pillHeight);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await harness.close();
  });

  test('sanitizer strips evidence tags and sender metadata', () {
    expect(
      sanitizeEvidenceText(
        'MAIL SUBJECT: Follow up from Maincode – Next Round '
        '(from Luke Borgnolo <luke@maincode.ai>)',
      ),
      'Follow up from Maincode – Next Round',
    );
    // Truncation can lose the closing paren; the sanitizer must not.
    expect(
      sanitizeEvidenceText(
        'MAIL SUBJECT: Follow up from Maincode – Next Round '
        '(from Luke Borgnolo …',
      ),
      'Follow up from Maincode – Next Round',
    );
    expect(
      sanitizeEvidenceText('NOTE TITLE: Quarterly planning — draft'),
      'Quarterly planning — draft',
    );
    expect(
      sanitizeEvidenceText('Call the dentist back'),
      'Call the dentist back',
    );
    expect(sanitizeEvidenceText('a' * 100).length, lessThanOrEqualTo(72));
    expect(sanitizeEvidenceText('a' * 100), endsWith('…'));
  });

  test('email subject prefers a clean reply subject from mail evidence', () {
    const suggestion = PillSuggestion(
      label: 'Follow up with Luke',
      prompt: 'Follow up with Luke',
      kind: PillSuggestionKind.email,
      email: 'luke@maincode.ai',
      evidence:
          'MAIL SUBJECT: Re: Next Round (from Luke Borgnolo '
          '<luke@maincode.ai>)',
    );
    expect(suggestion.emailSubject, 'Re: Next Round');
    const bare = PillSuggestion(
      label: 'Follow up with Luke',
      prompt: 'Follow up with Luke',
      kind: PillSuggestionKind.email,
    );
    expect(bare.emailSubject, 'Follow up with Luke');
  });

  test(
    'email dispatch launches a mailto with clean subject and drafted body',
    () async {
      final harness = _Harness();
      final controller = harness.controller(
        draftBody:
            'Hi Luke,\n\nThanks for the update on the next round — I wanted to '
            'follow up on where things stand. Let me know what you need from '
            'me to move forward.\n\nBest,\nMax',
      );
      const suggestion = PillSuggestion(
        label: 'Follow up with Luke',
        prompt: 'Help me with this task: Follow up with Luke.',
        kind: PillSuggestionKind.email,
        email: 'luke@maincode.ai',
        personHint: 'Luke',
        evidence:
            'MAIL SUBJECT: Follow up from Maincode – Next Round '
            '(from Luke Borgnolo <luke@maincode.ai>)',
      );

      await controller.summon();
      final choosing = controller.choose(suggestion);
      await pumpEventQueue();
      final lookup = harness.hub.searches.last;
      harness.hub.add(
        NativeEventMemorySearchResults(
          value: MemorySearchResults(
            requestId: lookup.requestId,
            query: lookup.query,
            items: const [
              MemorySearchItem(
                kind: 'claim',
                id: 'thread',
                excerpt:
                    'MAIL SUBJECT: Follow up from Maincode – Next Round '
                    '(from Luke Borgnolo <luke@maincode.ai>)',
                relevanceBasisPoints: 9000,
                evidenceIds: [],
              ),
            ],
            gaps: [],
          ),
        ),
      );
      await choosing;

      final mailto = harness.launchedLinks.single;
      expect(mailto.scheme, 'mailto');
      expect(mailto.path, 'luke@maincode.ai');
      expect(
        mailto.queryParameters['subject'],
        'Re: Follow up from Maincode – Next Round',
      );
      expect(
        mailto.queryParameters['subject'],
        isNot(contains('MAIL SUBJECT')),
      );
      expect(mailto.queryParameters['subject'], isNot(contains('(from')));
      expect(mailto.queryParameters['body'], startsWith('Hi Luke,'));
      expect(mailto.queryParameters['body'], contains('Best,'));
      // The draft prompt carries the thread evidence as context.
      expect(harness.draftPrompts.single, contains('Next Round'));

      controller.dispose();
      await harness.close();
    },
  );

  test(
    'memory items fill remaining slots after currents suggestions',
    () async {
      final harness = _Harness();
      final currents = CurrentsController(
        const CurrentsClient(_UnusedTransport()),
      )..items = [_card('Follow up with Luke about the next round')];
      final controller = harness.controller(currents: currents);

      await controller.summon();
      expect(controller.suggestions, hasLength(1));
      harness.hub.add(
        NativeEventMemorySearchResults(
          value: MemorySearchResults(
            requestId: harness.hub.searches.first.requestId,
            query: CursorPillController.suggestionQuery,
            items: const [
              MemorySearchItem(
                kind: 'claim',
                id: 'a',
                excerpt: 'Finish the quarterly report',
                relevanceBasisPoints: 9000,
                evidenceIds: [],
              ),
              MemorySearchItem(
                kind: 'claim',
                id: 'b',
                excerpt: 'Follow up with Luke about the next round',
                relevanceBasisPoints: 8500,
                evidenceIds: [],
              ),
              MemorySearchItem(
                kind: 'claim',
                id: 'c',
                excerpt: 'Call the dentist back',
                relevanceBasisPoints: 8000,
                evidenceIds: [],
              ),
            ],
            gaps: [],
          ),
        ),
      );

      expect(controller.suggestions, hasLength(3));
      expect(
        controller.suggestions.first.label,
        'Follow up with Luke about the next round',
      );
      expect(controller.suggestions.first.currentId, 'current-1');
      // The duplicate memory item is skipped; distinct items fill the slots.
      expect(controller.suggestions[1].label, 'Finish the quarterly report');
      expect(controller.suggestions[2].label, 'Call the dentist back');

      controller.dispose();
      await harness.close();
      currents.dispose();
    },
  );

  testWidgets('chips render in a single horizontal row', (tester) async {
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
          items: const [
            MemorySearchItem(
              kind: 'claim',
              id: 'a',
              excerpt: 'Finish the quarterly report',
              relevanceBasisPoints: 9000,
              evidenceIds: [],
            ),
            MemorySearchItem(
              kind: 'claim',
              id: 'b',
              excerpt: 'Call the dentist back',
              relevanceBasisPoints: 8000,
              evidenceIds: [],
            ),
            MemorySearchItem(
              kind: 'claim',
              id: 'c',
              excerpt: 'Reply to the design review thread',
              relevanceBasisPoints: 7000,
              evidenceIds: [],
            ),
          ],
          gaps: [],
        ),
      ),
    );
    await tester.pump();

    expect(controller.suggestions, hasLength(3));
    final chips = find.byKey(const Key('cursor_pill_chips'));
    expect(
      tester.widget<SingleChildScrollView>(chips).scrollDirection,
      Axis.horizontal,
    );
    final tops = [
      tester.getTopLeft(find.textContaining('quarterly report')).dy,
      tester.getTopLeft(find.textContaining('dentist')).dy,
      tester.getTopLeft(find.textContaining('design review')).dy,
    ];
    expect(tops.toSet(), hasLength(1));

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await harness.close();
  });

  testWidgets('chip shimmer entrance honors disabled animations', (
    tester,
  ) async {
    final harness = _Harness();
    final controller = harness.controller();
    Future<void> pumpPill({required bool disableAnimations}) =>
        tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: disableAnimations),
              child: Scaffold(body: CursorPill(controller: controller)),
            ),
          ),
        );

    await pumpPill(disableAnimations: true);
    await controller.summon();
    harness.hub.add(
      NativeEventMemorySearchResults(
        value: MemorySearchResults(
          requestId: harness.hub.searches.single.requestId,
          query: CursorPillController.suggestionQuery,
          items: const [
            MemorySearchItem(
              kind: 'claim',
              id: 'a',
              excerpt: 'Finish the quarterly report',
              relevanceBasisPoints: 9000,
              evidenceIds: [],
            ),
          ],
          gaps: [],
        ),
      ),
    );
    await tester.pump();
    // Reduced motion: the chip appears instantly with no shimmer sweep.
    expect(find.textContaining('quarterly report'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('cursor_pill_chips')),
        matching: find.byType(ShaderMask),
      ),
      findsNothing,
    );

    await controller.dismiss();
    await tester.pump();
    await pumpPill(disableAnimations: false);
    await controller.summon();
    harness.hub.add(
      NativeEventMemorySearchResults(
        value: MemorySearchResults(
          requestId: harness.hub.searches.last.requestId,
          query: CursorPillController.suggestionQuery,
          items: const [
            MemorySearchItem(
              kind: 'claim',
              id: 'a',
              excerpt: 'Finish the quarterly report',
              relevanceBasisPoints: 9000,
              evidenceIds: [],
            ),
          ],
          gaps: [],
        ),
      ),
    );
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('cursor_pill_chips')),
        matching: find.byType(ShaderMask),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('cursor_pill_chips')),
        matching: find.byType(ShaderMask),
      ),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await harness.close();
  });
}

CurrentCard _card(String title) => CurrentCard(
  title: title,
  summary: 'Reply to the latest message in the thread.',
  item: CurrentItem.candidate(
    id: 'current-1',
    evidence: [CurrentEvidence(sourceId: 'mail-1', reason: 'recent thread')],
    reason: 'recent thread',
    timing: CurrentTiming(surfaceAt: DateTime.utc(2026, 7, 22)),
    confidence: 0.9,
    proposedNextStep: 'Reply to Luke',
    createdAt: DateTime.utc(2026, 7, 22),
  ),
);

final class _UnusedTransport implements CurrentsTransport {
  const _UnusedTransport();

  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async =>
      throw StateError('transport must not be used');
}

final class _Harness {
  _Harness({this.stopTranscript = '', this.startVoiceError});

  final draftPrompts = <String>[];

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

  CursorPillController controller({
    String? draftBody,
    CurrentsController? currents,
  }) => CursorPillController(
    hub: hub,
    currents: currents,
    draft: draftBody == null
        ? null
        : (prompt, timeout) async {
            draftPrompts.add(prompt);
            return draftBody;
          },
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
