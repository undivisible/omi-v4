import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/cursor_pill_controller.dart';
import 'package:omi/features/pill_panel.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('primary engine host', () {
    late _HostHarness harness;

    setUp(() => harness = _HostHarness());
    tearDown(() => harness.close());

    testWidgets('mirrors the live surface into the panel engine', (
      tester,
    ) async {
      harness.controller.applyHostState(
        state: CursorPillState.input,
        suggestions: const [
          PillSuggestion(label: 'Reply to Luke', prompt: 'reply'),
          PillSuggestion(
            label: 'Open the deck',
            prompt: 'open',
            kind: PillSuggestionKind.link,
          ),
        ],
      );
      await tester.pump();

      final pushed = harness.pushes.last;
      expect(pushed['state'], 'input');
      expect((pushed['suggestions'] as List).map((entry) => entry['label']), [
        'Reply to Luke',
        'Open the deck',
      ]);
      expect((pushed['suggestions'] as List).last['kind'], 'link');
    });

    testWidgets('a relayed submission runs on the engine that owns services', (
      tester,
    ) async {
      await harness.controller.summon();
      await harness.host.handle(const MethodCall('submit', 'draft the note'));

      expect(harness.prompts, ['draft the note']);
      expect(harness.controller.state, CursorPillState.working);
    });

    testWidgets('a suggestion is acted on by index, not by its label', (
      tester,
    ) async {
      harness.controller.applyHostState(
        state: CursorPillState.input,
        suggestions: const [
          PillSuggestion(label: 'first', prompt: 'first prompt'),
          PillSuggestion(label: 'second', prompt: 'second prompt'),
        ],
      );
      await harness.host.handle(const MethodCall('choose', 1));

      expect(harness.prompts, ['second prompt']);
    });

    testWidgets('the panel asks the host for AI completions', (tester) async {
      final completion = await harness.host.handle(
        const MethodCall('completion', {
          'prompt': 'Typed so far: "open sl"',
          'timeoutMs': 1500,
        }),
      );

      expect(completion, 'open slack');
      expect(harness.draftPrompts.single, contains('open sl'));
    });

    testWidgets('a dismissed panel collapses the live surface', (tester) async {
      await harness.controller.summon();
      await harness.host.handle(const MethodCall('dismiss'));

      expect(harness.controller.state, CursorPillState.hidden);
    });

    testWidgets(
      'the panel is summoned once and never re-presented while it is up',
      (tester) async {
        await harness.controller.summon();
        expect(harness.presents, [true]);

        // Everything that happens while the user types pushes state at the
        // panel; none of it may ask the Runner to place the window again, or
        // the overlay walks off after the cursor.
        harness.controller.inputChanged('open sl');
        await tester.pump(const Duration(milliseconds: 400));
        harness.controller.applyHostState(
          state: CursorPillState.input,
          status: 'Thinking…',
        );
        await harness.controller.summon();
        await harness.controller.toggleOverlay();
        await tester.pump();

        expect(harness.presents, [true]);
        expect(harness.pushes.length, greaterThan(1));
      },
    );
  });

  group('panel engine client', () {
    late _ClientHarness harness;

    setUp(() => harness = _ClientHarness());
    tearDown(() => harness.close());

    testWidgets('renders the state pushed from the primary engine', (
      tester,
    ) async {
      await harness.client.handle(
        const MethodCall('state', {
          'state': 'input',
          'suggestions': [
            {'label': 'Reply to Luke', 'kind': 'email'},
          ],
          'status': null,
          'error': null,
        }),
      );

      expect(harness.client.controller.state, CursorPillState.input);
      expect(
        harness.client.controller.suggestions.single.label,
        'Reply to Luke',
      );
      expect(
        harness.client.controller.suggestions.single.kind,
        PillSuggestionKind.email,
      );
      expect(harness.calls.where((call) => call.method == 'close'), isEmpty);
    });

    testWidgets('anything but typing closes the panel window', (tester) async {
      await harness.client.handle(
        const MethodCall('state', {'state': 'working', 'status': 'Working…'}),
      );

      expect(harness.client.controller.state, CursorPillState.working);
      expect(harness.calls.map((call) => call.method), contains('close'));
    });

    testWidgets('every submission is relayed verbatim, launcher included', (
      tester,
    ) async {
      await harness.client.handle(const MethodCall('show'));
      await harness.client.controller.submit('open safari');

      final submit = harness.calls.firstWhere(
        (call) => call.method == 'submit',
      );
      expect(submit.arguments, 'open safari');
      expect(
        harness.calls.map((call) => call.method),
        isNot(contains('launch')),
      );
    });

    testWidgets('choosing a suggestion relays its index', (tester) async {
      await harness.client.handle(
        const MethodCall('state', {
          'state': 'input',
          'suggestions': [
            {'label': 'first', 'kind': 'chat'},
            {'label': 'second', 'kind': 'chat'},
          ],
        }),
      );
      await harness.client.controller.choose(
        harness.client.controller.suggestions[1],
      );

      final choose = harness.calls.firstWhere(
        (call) => call.method == 'choose',
      );
      expect(choose.arguments, 1);
    });

    testWidgets('the ghost completion still runs inside the panel', (
      tester,
    ) async {
      await harness.client.handle(const MethodCall('show'));
      harness.client.controller.inputChanged('open sl');
      await tester.pump(const Duration(milliseconds: 350));

      expect(harness.calls.map((call) => call.method), contains('completion'));
      await tester.pump();
      expect(
        harness.client.controller.predictedRemainder('open sl'),
        'ack and check messages',
      );
    });

    testWidgets('a hidden panel drops the surface it was rendering', (
      tester,
    ) async {
      await harness.client.handle(const MethodCall('show'));
      await harness.client.handle(const MethodCall('hide'));

      expect(harness.client.controller.state, CursorPillState.hidden);
    });
  });
}

final class _HostHarness {
  _HostHarness() {
    controller = CursorPillController(
      hub: const UnavailableNativeHub('test'),
      events: const Stream.empty(),
      startVoice: () async {},
      stopVoice: () async => '',
      cancelVoice: () async {},
      sendPrompt: (text) async {
        prompts.add(text);
        return 'request-1';
      },
      level: ValueNotifier<double>(0),
      presentWindow: (centered) async => presents.add(centered),
      draft: (prompt, timeout) async {
        draftPrompts.add(prompt);
        return 'open slack';
      },
    );
    host = PillPanelHost(
      controller: controller,
      draft: (prompt, timeout) async {
        draftPrompts.add(prompt);
        return 'open slack';
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'pushState') {
            pushes.add(Map<String, Object?>.from(call.arguments as Map));
          }
          return null;
        });
    host.start();
  }

  static const _channel = MethodChannel(pillHostChannelName);

  late final CursorPillController controller;
  late final PillPanelHost host;
  final prompts = <String>[];
  final draftPrompts = <String>[];
  final presents = <bool>[];
  final pushes = <Map<String, Object?>>[];

  void close() {
    host.dispose();
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

final class _ClientHarness {
  _ClientHarness() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'ready' => <Object?, Object?>{'visible': false},
            'completion' => 'open slack and check messages',
            _ => null,
          };
        });
    client = PillPanelClient()..start();
  }

  static const _channel = MethodChannel(pillPanelChannelName);

  late final PillPanelClient client;
  final calls = <MethodCall>[];

  void close() {
    client.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
