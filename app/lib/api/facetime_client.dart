import 'worker_http.dart';

/// A placed call: the handle that was rung and the shareable link the bridge
/// joins.
final class FaceTimeCall {
  const FaceTimeCall({required this.handle, required this.link});

  final String handle;
  final String link;
}

/// The provider has FaceTime calling switched off. This is a product state,
/// not a fault: it is explained to the user, never retried, and the feature
/// starts working on its own once the provider enables it.
final class FaceTimeUnavailableException implements Exception {
  const FaceTimeUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The FaceTime surface the UI talks to. An interface so the call flow can be
/// exercised — including the unavailable state — without a worker.
abstract interface class FaceTimeClient {
  Future<FaceTimeCall> placeCall({
    required String handle,
    String? idempotencyKey,
  });
}

final class WorkerFaceTimeClient implements FaceTimeClient {
  const WorkerFaceTimeClient(this._client);

  final WorkerHttpClient _client;

  @override
  Future<FaceTimeCall> placeCall({
    required String handle,
    String? idempotencyKey,
  }) async {
    final response = await _client.send(
      method: 'POST',
      path: '/api/v1/facetime/calls',
      body: {'handle': handle, 'idempotencyKey': ?idempotencyKey},
    );
    final body = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = body is Map<String, Object?> && body['error'] is String
          ? body['error']! as String
          : 'FaceTime call failed (${response.statusCode})';
      // The provider's own switch. Distinguished by `code`, not by status,
      // exactly as the API contract asks.
      if (body is Map<String, Object?> &&
          body['code'] == 'facetime_unavailable') {
        throw FaceTimeUnavailableException(error);
      }
      throw WorkerResponseException(error, statusCode: response.statusCode);
    }
    final call = body is Map<String, Object?> ? body['call'] : null;
    if (call is! Map<String, Object?> ||
        call['handle'] is! String ||
        call['link'] is! String) {
      throw const WorkerResponseException('Worker returned an invalid call');
    }
    final link = call['link']! as String;
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const WorkerResponseException(
        'Worker returned an unsafe call link',
      );
    }
    return FaceTimeCall(handle: call['handle']! as String, link: link);
  }
}
