import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/api/byok_client.dart';
import 'package:omi/features/onboarding/byok_step.dart';
import 'package:omi/native/generated/signals/signals.dart'
    show AssistantProvider;
import 'package:omi/providers/provider_credentials.dart';
import 'package:omi/providers/provider_models.dart';

// A worker stand-in. It answers with server-shaped payloads and records what
// the step asked for, so the test can assert the step never sends a price.
final class _FakeByokClient implements ByokClient {
  final int negotiatedPriceCents = 900;
  final List<String> calls = [];
  final List<String> messages = [];

  @override
  Future<ByokPlan> getPlan() async {
    calls.add('getPlan');
    return const ByokPlan(
      standardPriceCents: 1200,
      floorPriceCents: 700,
      priceCents: 1200,
      negotiable: true,
    );
  }

  @override
  Future<ByokPlan> takeStandardPrice() async {
    calls.add('takeStandardPrice');
    return const ByokPlan(
      standardPriceCents: 1200,
      floorPriceCents: 700,
      priceCents: 1200,
      negotiable: false,
      outcome: 'standard',
    );
  }

  @override
  Future<ByokNegotiationOpening> startNegotiation() async {
    calls.add('startNegotiation');
    return const ByokNegotiationOpening(
      sessionId: 'session-1',
      priceCents: 1200,
      standardPriceCents: 1200,
      turnsRemaining: 6,
      transcript: [
        ByokNegotiationMessage(fromOmi: true, content: 'Tell me why.'),
      ],
    );
  }

  @override
  Future<ByokNegotiationTurn> send(String sessionId, String message) async {
    calls.add('send');
    messages.add(message);
    return ByokNegotiationTurn(
      reply: 'That is a fair point.',
      priceCents: negotiatedPriceCents,
      turnsRemaining: 5,
      conceded: true,
    );
  }

  @override
  Future<ByokPlan> accept(String sessionId) async {
    calls.add('accept:$sessionId');
    return ByokPlan(
      standardPriceCents: 1200,
      floorPriceCents: 700,
      priceCents: negotiatedPriceCents,
      negotiable: false,
      outcome: 'negotiated',
    );
  }
}

Widget _host(Widget child, {bool reducedMotion = false}) => MaterialApp(
  theme: ThemeData.dark(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reducedMotion),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

Future<void> _connect(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('byok_model')), 'gpt-5');
  await tester.enterText(find.byKey(const Key('byok_key')), 'sk-test');
  await tester.tap(find.byKey(const Key('byok_connect')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('connecting a key opens the negotiation at the plan price', (
    tester,
  ) async {
    final client = _FakeByokClient();
    final connected = <ProviderCredential>[];
    await tester.pumpWidget(
      _host(
        OnboardingByokStep(
          client: client,
          onConnect: (credential) async => connected.add(credential),
          onFinish: () {},
        ),
      ),
    );

    await _connect(tester);

    expect(connected.single.model, 'gpt-5');
    expect(client.calls, contains('getPlan'));
    expect(find.byKey(const Key('byok_price')), findsOneWidget);
    expect(find.text('\$12 a month'), findsOneWidget);
  });

  testWidgets('a conceded turn shows the price the worker returned', (
    tester,
  ) async {
    final client = _FakeByokClient();
    await tester.pumpWidget(
      _host(
        OnboardingByokStep(
          client: client,
          onConnect: (_) async {},
          onFinish: () {},
        ),
      ),
    );
    await _connect(tester);

    await tester.tap(find.byKey(const Key('byok_negotiate')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('byok_message')),
      'I am a student.',
    );
    await tester.tap(find.byKey(const Key('byok_send')));
    await tester.pumpAndSettle();

    expect(client.messages, ['I am a student.']);
    expect(find.text('\$9 a month'), findsOneWidget);
    expect(find.text('That is a fair point.'), findsOneWidget);
    // Accepting sends the session id and nothing else; no price leaves here.
    await tester.tap(find.byKey(const Key('byok_accept')));
    await tester.pumpAndSettle();
    expect(client.calls, contains('accept:session-1'));
    expect(find.text('Settled.'), findsOneWidget);
  });

  testWidgets('skipping the negotiation settles at the standard price', (
    tester,
  ) async {
    final client = _FakeByokClient();
    var finished = false;
    await tester.pumpWidget(
      _host(
        OnboardingByokStep(
          client: client,
          onConnect: (_) async {},
          onFinish: () => finished = true,
        ),
      ),
    );
    await _connect(tester);

    await tester.tap(find.byKey(const Key('byok_take_standard')));
    await tester.pumpAndSettle();

    expect(client.calls, contains('takeStandardPrice'));
    expect(client.calls, isNot(contains('startNegotiation')));
    expect(find.text('\$12 a month'), findsOneWidget);
    await tester.tap(find.byKey(const Key('byok_done')));
    await tester.pump();
    expect(finished, isTrue);
  });

  testWidgets('the whole step can be skipped before connecting anything', (
    tester,
  ) async {
    final client = _FakeByokClient();
    var finished = false;
    await tester.pumpWidget(
      _host(
        OnboardingByokStep(
          client: client,
          onConnect: (_) async {},
          onFinish: () => finished = true,
        ),
      ),
    );

    await tester.ensureVisible(find.byKey(const Key('byok_skip_connect')));
    await tester.tap(find.byKey(const Key('byok_skip_connect')));
    await tester.pump();

    expect(finished, isTrue);
    expect(client.calls, isEmpty);
  });

  testWidgets('reduced motion drops the phase transition', (tester) async {
    await tester.pumpWidget(
      _host(
        OnboardingByokStep(
          client: _FakeByokClient(),
          onConnect: (_) async {},
          onFinish: () {},
        ),
        reducedMotion: true,
      ),
    );

    expect(find.byType(AnimatedSwitcher), findsNothing);
  });

  testWidgets('the model field is seeded from the selected provider', (
    tester,
  ) async {
    final connected = <ProviderCredential>[];
    await tester.pumpWidget(
      _host(
        OnboardingByokStep(
          client: null,
          onConnect: (credential) async => connected.add(credential),
          onFinish: () {},
        ),
      ),
    );

    expect(
      find.text(defaultBalancedModel[AssistantProvider.openAi]!),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('byok_provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AssistantProvider.anthropic.name).last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('byok_key')), 'sk-test');
    await tester.tap(find.byKey(const Key('byok_connect')));
    await tester.pumpAndSettle();

    expect(
      connected.single.model,
      defaultBalancedModel[AssistantProvider.anthropic],
    );
  });
}
