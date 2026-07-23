import 'worker_http.dart';

/// The BYOK plan as the worker reports it. Every figure here is server
/// computed: the app displays these numbers and never proposes one.
final class ByokPlan {
  const ByokPlan({
    required this.standardPriceCents,
    required this.floorPriceCents,
    required this.priceCents,
    required this.negotiable,
    this.outcome,
  });

  final int standardPriceCents;
  final int floorPriceCents;
  final int priceCents;
  final bool negotiable;

  /// `negotiated`, `standard`, or null when nothing has been settled yet.
  final String? outcome;

  bool get settled => outcome != null;
}

final class ByokNegotiationOpening {
  const ByokNegotiationOpening({
    required this.sessionId,
    required this.priceCents,
    required this.standardPriceCents,
    required this.turnsRemaining,
    required this.transcript,
  });

  final String sessionId;
  final int priceCents;
  final int standardPriceCents;
  final int turnsRemaining;
  final List<ByokNegotiationMessage> transcript;
}

final class ByokNegotiationMessage {
  const ByokNegotiationMessage({required this.fromOmi, required this.content});

  final bool fromOmi;
  final String content;
}

final class ByokNegotiationTurn {
  const ByokNegotiationTurn({
    required this.reply,
    required this.priceCents,
    required this.turnsRemaining,
    required this.conceded,
  });

  final String reply;
  final int priceCents;
  final int turnsRemaining;
  final bool conceded;
}

/// The BYOK surface the UI talks to. An interface so the negotiation step can
/// be exercised without a worker.
abstract interface class ByokClient {
  Future<ByokPlan> getPlan();
  Future<ByokPlan> takeStandardPrice();
  Future<ByokNegotiationOpening> startNegotiation();
  Future<ByokNegotiationTurn> send(String sessionId, String message);
  Future<ByokPlan> accept(String sessionId);
}

final class WorkerByokClient implements ByokClient {
  const WorkerByokClient(this._client);

  final WorkerHttpClient _client;

  @override
  Future<ByokPlan> getPlan() async =>
      _plan(await _client.send(method: 'GET', path: '/v1/byok/plan'));

  /// Takes the standard BYOK price without negotiating. Always available.
  @override
  Future<ByokPlan> takeStandardPrice() async =>
      _plan(await _client.send(method: 'POST', path: '/v1/byok/plan/standard'));

  @override
  Future<ByokNegotiationOpening> startNegotiation() async {
    final body = _body(
      await _client.send(method: 'POST', path: '/v1/byok/negotiation'),
    );
    final sessionId = body['sessionId'];
    final transcript = body['transcript'];
    if (sessionId is! String || sessionId.isEmpty || transcript is! List) {
      throw const WorkerResponseException(
        'Worker returned invalid negotiation',
      );
    }
    return ByokNegotiationOpening(
      sessionId: sessionId,
      priceCents: _cents(body['priceCents']),
      standardPriceCents: _cents(body['standardPriceCents']),
      turnsRemaining: _cents(body['turnsRemaining']),
      transcript: [
        for (final entry in transcript)
          if (entry is Map<String, Object?> && entry['content'] is String)
            ByokNegotiationMessage(
              fromOmi: entry['role'] != 'user',
              content: entry['content']! as String,
            ),
      ],
    );
  }

  @override
  Future<ByokNegotiationTurn> send(String sessionId, String message) async {
    final body = _body(
      await _client.send(
        method: 'POST',
        path: '/v1/byok/negotiation/$sessionId/message',
        body: {'message': message},
      ),
    );
    final reply = body['reply'];
    if (reply is! String) {
      throw const WorkerResponseException('Worker returned invalid reply');
    }
    return ByokNegotiationTurn(
      reply: reply,
      priceCents: _cents(body['priceCents']),
      turnsRemaining: _cents(body['turnsRemaining']),
      conceded: body['conceded'] == true,
    );
  }

  /// Settles the negotiation. The price is recomputed by the worker from what
  /// the conversation earned; nothing is sent from here.
  @override
  Future<ByokPlan> accept(String sessionId) async => _plan(
    await _client.send(
      method: 'POST',
      path: '/v1/byok/negotiation/$sessionId/accept',
    ),
  );

  ByokPlan _plan(({int statusCode, Object? body}) response) {
    final body = _body(response);
    final outcome = body['outcome'];
    if (outcome != null && outcome is! String) {
      throw const WorkerResponseException('Worker returned invalid plan');
    }
    return ByokPlan(
      standardPriceCents: _cents(body['standardPriceCents']),
      floorPriceCents: _cents(body['floorPriceCents']),
      priceCents: _cents(body['priceCents']),
      negotiable: body['negotiable'] == true,
      outcome: outcome as String?,
    );
  }

  Map<String, Object?> _body(({int statusCode, Object? body}) response) {
    final body = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WorkerResponseException(
        body is Map<String, Object?> && body['error'] is String
            ? body['error']! as String
            : 'BYOK request failed',
      );
    }
    if (body is! Map<String, Object?>) {
      throw const WorkerResponseException('Worker returned invalid BYOK body');
    }
    return body;
  }

  int _cents(Object? value) {
    if (value is! int || value < 0) {
      throw const WorkerResponseException('Worker returned invalid amount');
    }
    return value;
  }
}

String formatPriceCents(int cents) {
  final dollars = cents ~/ 100;
  final remainder = cents % 100;
  return remainder == 0
      ? '\$$dollars'
      : '\$$dollars.${remainder.toString().padLeft(2, '0')}';
}
