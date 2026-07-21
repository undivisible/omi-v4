import 'currents.dart';

enum CurrentsHttpMethod { get, post }

final class CurrentsRequest {
  const CurrentsRequest({required this.method, required this.path, this.body});

  final CurrentsHttpMethod method;
  final String path;
  final Map<String, Object?>? body;
}

final class CurrentsResponse {
  const CurrentsResponse({required this.statusCode, this.body});

  final int statusCode;
  final Object? body;
}

abstract interface class CurrentsTransport {
  Future<CurrentsResponse> send(CurrentsRequest request);
}

final class CurrentCard {
  const CurrentCard({
    required this.item,
    required this.title,
    required this.summary,
  });

  factory CurrentCard.fromJson(Map<String, Object?> json) => CurrentCard(
    item: CurrentItem.fromJson(json),
    title: _text(json, 'title'),
    summary: _text(json, 'summary'),
  );

  final CurrentItem item;
  final String title;
  final String summary;
}

final class CurrentActionHandoff {
  const CurrentActionHandoff({
    required this.executionId,
    required this.approvalNonce,
    required this.instruction,
  });

  final String executionId;
  final String approvalNonce;
  final String instruction;
}

enum CurrentExecutionOutcome { succeeded, failed, outcomeUnknown }

final class CurrentsClientException implements Exception {
  const CurrentsClientException(this.message);

  final String message;
}

final class CurrentsClient {
  const CurrentsClient(this._transport);

  final CurrentsTransport _transport;

  Future<void> generate() async {
    await _send(
      const CurrentsRequest(
        method: CurrentsHttpMethod.post,
        path: '/v1/currents/generate',
        body: {},
      ),
    );
  }

  Future<List<CurrentCard>> list() async {
    final body = await _send(
      const CurrentsRequest(
        method: CurrentsHttpMethod.get,
        path: '/v1/currents',
      ),
    );
    final values = body['currents'];
    if (values is! List<Object?>) {
      throw const CurrentsClientException('currents must be a list');
    }
    return List.unmodifiable(
      values.map((value) {
        if (value is! Map<String, Object?>) {
          throw const CurrentsClientException('current must be an object');
        }
        try {
          return CurrentCard.fromJson(value);
        } on FormatException catch (error) {
          throw CurrentsClientException(error.message);
        }
      }),
    );
  }

  Future<CurrentCard> feedback(
    String id,
    CurrentStatus status, {
    DateTime? snoozedUntil,
  }) async {
    if (status != CurrentStatus.dismissed && status != CurrentStatus.snoozed) {
      throw const CurrentsClientException('feedback must dismiss or snooze');
    }
    final body = await _send(
      CurrentsRequest(
        method: CurrentsHttpMethod.post,
        path: '/v1/currents/$id/feedback',
        body: {
          'kind': status.name,
          if (snoozedUntil != null)
            'snoozedUntil': snoozedUntil.millisecondsSinceEpoch,
        },
      ),
    );
    return CurrentCard.fromJson(_map(body, 'current'));
  }

  Future<CurrentActionHandoff> accept(String id) async {
    final body = await _send(
      CurrentsRequest(
        method: CurrentsHttpMethod.post,
        path: '/v1/currents/$id/accept',
        body: const {},
      ),
    );
    final action = _map(body, 'action');
    return CurrentActionHandoff(
      executionId: _text(body, 'executionId'),
      approvalNonce: _text(body, 'approvalNonce'),
      instruction: _text(action, 'instruction'),
    );
  }

  Future<void> approve(CurrentActionHandoff handoff) async {
    await _send(
      CurrentsRequest(
        method: CurrentsHttpMethod.post,
        path: '/v1/currents/executions/${handoff.executionId}/approve',
        body: {'approvalNonce': handoff.approvalNonce},
      ),
    );
  }

  Future<void> reject(CurrentActionHandoff handoff) async {
    await _send(
      CurrentsRequest(
        method: CurrentsHttpMethod.post,
        path: '/v1/currents/executions/${handoff.executionId}/reject',
        body: {'approvalNonce': handoff.approvalNonce},
      ),
    );
  }

  Future<void> recordOutcome(
    CurrentActionHandoff handoff,
    CurrentExecutionOutcome outcome,
    String detail,
  ) async {
    if (detail.trim().isEmpty) {
      throw const CurrentsClientException('outcome detail must not be empty');
    }
    await _send(
      CurrentsRequest(
        method: CurrentsHttpMethod.post,
        path: '/v1/currents/executions/${handoff.executionId}/outcome',
        body: {
          'state': switch (outcome) {
            CurrentExecutionOutcome.succeeded => 'succeeded',
            CurrentExecutionOutcome.failed => 'failed',
            CurrentExecutionOutcome.outcomeUnknown => 'outcome_unknown',
          },
          'detail': detail,
        },
      ),
    );
  }

  Future<Map<String, Object?>> _send(CurrentsRequest request) async {
    final CurrentsResponse response;
    try {
      response = await _transport.send(request);
    } catch (error) {
      throw CurrentsClientException(error.toString());
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = response.body;
      throw CurrentsClientException(
        body is Map && body['error'] is String
            ? body['error']! as String
            : 'Currents request failed',
      );
    }
    if (response.body is! Map<String, Object?>) {
      throw const CurrentsClientException('response must be an object');
    }
    return response.body! as Map<String, Object?>;
  }
}

Map<String, Object?> _map(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map<String, Object?>) {
    throw CurrentsClientException('$key must be an object');
  }
  return value;
}

String _text(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw CurrentsClientException('$key must be a non-empty string');
  }
  return value;
}
