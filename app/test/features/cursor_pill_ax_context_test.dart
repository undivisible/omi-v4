import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/ax_context.dart';
import 'package:omi/features/cursor_pill_controller.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  group('buildOverlayPrompt', () {
    test('bare question when there is nothing on hand', () {
      expect(
        buildOverlayPrompt(question: 'what do I write?'),
        'what do I write?',
      );
    });

    test('labels every populated section under one context block', () {
      final prompt = buildOverlayPrompt(
        question: 'what do I reply?',
        context: const AxContextSnapshot(
          appName: 'Mail',
          bundleId: 'com.apple.mail',
          windowTitle: 'Re: Next Round',
          focusedText: 'Hi Luke, thanks for',
          selectedText: 'thanks for',
          surrounding: 'From: Luke\nWhen can you start?',
          truncated: true,
        ),
        memory: const [
          PillSuggestion(label: 'Luke raise', prompt: 'Luke offered a raise'),
        ],
      );
      expect(prompt, startsWith('what do I reply?'));
      expect(prompt, contains('App: Mail (com.apple.mail)'));
      expect(prompt, contains('Window: Re: Next Round'));
      expect(prompt, contains('What I have already written:'));
      expect(prompt, contains('Hi Luke, thanks for'));
      expect(prompt, contains('Currently selected:'));
      expect(prompt, contains('On screen:'));
      expect(prompt, contains('When can you start?'));
      expect(prompt, contains('… (truncated)'));
      expect(prompt, contains('From my memory:'));
      expect(prompt, contains('- Luke offered a raise'));
    });

    test('a secure snapshot contributes no written text', () {
      final prompt = buildOverlayPrompt(
        question: 'what is my password hint?',
        context: const AxContextSnapshot(appName: 'Safari', secure: true),
      );
      // The app is still context, but the focused (password) field is never
      // present, so nothing the user typed leaks into the prompt.
      expect(prompt, contains('App: Safari'));
      expect(prompt, isNot(contains('What I have already written')));
    });
  });

  group('_sendToAgent enrichment', () {
    test('feeds the fetched snapshot into the outgoing prompt', () async {
      final harness = _Harness(
        snapshot: const AxContextSnapshot(
          appName: 'Mail',
          bundleId: 'com.apple.mail',
          focusedText: 'Hi Luke,',
          surrounding: 'From: Luke\nWhat is your timeline?',
        ),
      );
      final controller = harness.controller();

      await controller.summon();
      // Seed the session's memory matches, folded in alongside the snapshot.
      harness.hub.add(
        NativeEventMemorySearchResults(
          value: MemorySearchResults(
            requestId: harness.hub.searches.single.requestId,
            query: CursorPillController.suggestionQuery,
            items: const [
              MemorySearchItem(
                kind: 'claim',
                id: 'a',
                excerpt: 'Luke asked about the timeline last week',
                relevanceBasisPoints: 9000,
                evidenceIds: [],
              ),
            ],
            gaps: [],
          ),
        ),
      );
      await pumpEventQueue();

      await controller.submit('what do I write back?');
      expect(harness.fetches, 1);
      final prompt = harness.prompts.single;
      expect(prompt, startsWith('what do I write back?'));
      expect(prompt, contains('App: Mail (com.apple.mail)'));
      expect(prompt, contains('Hi Luke,'));
      expect(prompt, contains('What is your timeline?'));
      expect(prompt, contains('Luke asked about the timeline'));
      expect(controller.state, CursorPillState.working);

      controller.dispose();
      await harness.close();
    });

    test('a secure snapshot degrades to the plain question', () async {
      final harness = _Harness(snapshot: const AxContextSnapshot(secure: true));
      final controller = harness.controller();

      await controller.summon();
      await controller.submit('draft a reply');
      expect(harness.prompts.single, 'draft a reply');

      controller.dispose();
      await harness.close();
    });

    test('a slow snapshot is abandoned and the plain question sent', () async {
      final harness = _Harness(
        snapshotDelay: const Duration(seconds: 5),
        snapshot: const AxContextSnapshot(appName: 'Mail'),
      );
      final controller = harness.controller(
        axContextTimeout: const Duration(milliseconds: 20),
      );

      await controller.summon();
      await controller.submit('summarize this');
      expect(harness.prompts.single, 'summarize this');

      controller.dispose();
      await harness.close();
    });

    test('no fetcher (off macOS) sends the bare question', () async {
      final harness = _Harness();
      final controller = harness.controller(withFetcher: false);

      await controller.summon();
      await controller.submit('what should I say?');
      expect(harness.fetches, 0);
      expect(harness.prompts.single, 'what should I say?');

      controller.dispose();
      await harness.close();
    });
  });
}

final class _Harness {
  _Harness({this.snapshot = AxContextSnapshot.empty, this.snapshotDelay});

  final AxContextSnapshot snapshot;
  final Duration? snapshotDelay;
  final hub = _FakeNativeHub();
  final level = ValueNotifier<double>(0);
  final prompts = <String>[];
  int fetches = 0;

  CursorPillController controller({
    bool withFetcher = true,
    Duration axContextTimeout = const Duration(milliseconds: 600),
  }) => CursorPillController(
    hub: hub,
    events: hub.events,
    startVoice: () async {},
    stopVoice: () async => '',
    cancelVoice: () async {},
    sendPrompt: (text) async {
      prompts.add(text);
      return 'req-${prompts.length}';
    },
    fetchAxContext: withFetcher
        ? () async {
            fetches += 1;
            if (snapshotDelay case final delay?) {
              await Future<void>.delayed(delay);
            }
            return snapshot;
          }
        : null,
    axContextTimeout: axContextTimeout,
    openFlashDuration: Duration.zero,
    level: level,
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
