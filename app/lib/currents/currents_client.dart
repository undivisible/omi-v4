import 'currents.dart';

const _currentAuthorityReceiptVersion = 'omi-current-authority-v1';
final _actionHashPattern = RegExp(r'^[0-9a-f]{64}$');
final _receiptTokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

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
    this.sourceKind,
    this.metadata,
  });

  factory CurrentCard.fromJson(Map<String, Object?> json) => CurrentCard(
    item: CurrentItem.fromJson(json),
    title: _text(json, 'title'),
    summary: _text(json, 'summary'),
    sourceKind: _optionalText(json, 'sourceKind'),
    metadata: json['metadata'] is Map
        ? (json['metadata'] as Map).cast<String, Object?>()
        : null,
  );

  final CurrentItem item;
  final String title;
  final String summary;
  final String? sourceKind;
  final Map<String, Object?>? metadata;
}

final class CurrentActionHandoff {
  const CurrentActionHandoff({
    required this.executionId,
    required this.approvalNonce,
    required this.instruction,
    required this.policyGeneration,
  });

  final String executionId;
  final String approvalNonce;
  final String instruction;
  final int policyGeneration;
}

final class CurrentApprovalReceipt {
  const CurrentApprovalReceipt({
    required this.version,
    required this.receiptId,
    required this.receiptToken,
    required this.subject,
    required this.proposalId,
    required this.operationId,
    required this.actionHash,
    required this.policyGeneration,
    required this.risk,
    required this.issuedAtMs,
    required this.expiresAtMs,
  });

  final String version;
  final String receiptId;
  final String receiptToken;
  final String subject;
  final String proposalId;
  final String operationId;
  final String actionHash;
  final int policyGeneration;
  final String risk;
  final int issuedAtMs;
  final int expiresAtMs;
}

enum CurrentExecutionOutcome {
  succeeded,
  failed,
  cancelledBeforeEffect,
  expiredBeforeEffect,
  outcomeUnknown,
}

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
      policyGeneration: _integer(body, 'policyGeneration'),
    );
  }

  Future<CurrentApprovalReceipt> approve(
    CurrentActionHandoff handoff, {
    required String subject,
    required String proposalId,
    required String operationId,
    required String actionHash,
    required String risk,
  }) async {
    final body = await _send(
      CurrentsRequest(
        method: CurrentsHttpMethod.post,
        path: '/v1/currents/executions/${handoff.executionId}/approve',
        body: {
          'approvalNonce': handoff.approvalNonce,
          'proposalId': proposalId,
          'operationId': operationId,
          'actionHash': actionHash,
          'risk': risk,
          'generation': handoff.policyGeneration,
        },
      ),
    );
    final value = _map(body, 'receipt');
    final receipt = CurrentApprovalReceipt(
      version: _text(value, 'version'),
      receiptId: _text(value, 'receiptId'),
      receiptToken: _text(value, 'receiptToken'),
      subject: _text(value, 'subject'),
      proposalId: _text(value, 'proposalId'),
      operationId: _text(value, 'operationId'),
      actionHash: _text(value, 'actionHash'),
      policyGeneration: _integer(value, 'policyGeneration'),
      risk: _text(value, 'risk'),
      issuedAtMs: _integer(value, 'issuedAtMs'),
      expiresAtMs: _integer(value, 'expiresAtMs'),
    );
    if (receipt.version != _currentAuthorityReceiptVersion ||
        !_receiptTokenPattern.hasMatch(receipt.receiptToken) ||
        receipt.subject != subject ||
        receipt.proposalId != proposalId ||
        receipt.operationId != operationId ||
        receipt.actionHash != actionHash ||
        !_actionHashPattern.hasMatch(receipt.actionHash) ||
        receipt.policyGeneration != handoff.policyGeneration ||
        receipt.risk != risk ||
        receipt.expiresAtMs <= receipt.issuedAtMs ||
        receipt.expiresAtMs <= DateTime.now().millisecondsSinceEpoch) {
      throw const CurrentsClientException('approval receipt is invalid');
    }
    return receipt;
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
            CurrentExecutionOutcome.cancelledBeforeEffect =>
              'cancelled_before_effect',
            CurrentExecutionOutcome.expiredBeforeEffect =>
              'expired_before_effect',
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

String? _optionalText(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw CurrentsClientException('$key must be a non-empty string or null');
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

int _integer(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) {
    throw CurrentsClientException('$key must be a non-negative integer');
  }
  return value;
}
