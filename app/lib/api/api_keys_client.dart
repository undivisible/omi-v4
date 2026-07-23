import 'worker_http.dart';

/// A scope an `omi_sk_` key can carry. The wire names are the worker's; the
/// summaries are what the settings UI shows next to each checkbox so a scope
/// is never granted blind.
enum ApiKeyScope {
  memoryRead('memory:read', 'Search and list memories'),
  currentsRead('currents:read', 'Read currents'),
  currentsWrite('currents:write', 'Create currents'),
  conversationsRead(
    'conversations:read',
    'Read conversation messages and meeting notes',
  ),
  assistantWrite('assistant:write', 'Ask Omi (needs an active Omi AI plan)'),
  facetimeWrite('facetime:write', 'Place FaceTime calls'),
  speechWrite(
    'speech:write',
    'Transcribe and synthesise speech (needs an active Omi AI plan)',
  );

  const ApiKeyScope(this.wireName, this.summary);

  final String wireName;
  final String summary;

  static ApiKeyScope? tryParse(String name) {
    for (final scope in values) {
      if (scope.wireName == name) return scope;
    }
    return null;
  }
}

/// A key as the worker lists it. The plaintext credential is never part of
/// this: it exists only in the single creation response.
final class ApiKeySummary {
  const ApiKeySummary({
    required this.id,
    required this.name,
    required this.prefix,
    required this.scopes,
    required this.createdAt,
    this.lastUsedAt,
    this.expiresAt,
    this.revokedAt,
  });

  final String id;
  final String name;

  /// The public part of the key, `omi_sk_` plus eight hex characters. Enough
  /// to recognise a key, useless as a credential.
  final String prefix;
  final List<ApiKeyScope> scopes;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final DateTime? expiresAt;
  final DateTime? revokedAt;

  bool get revoked => revokedAt != null;
}

/// The one and only moment the plaintext key exists in the app. It is handed
/// to the UI, offered for copying, and dropped: nothing writes it to disk and
/// nothing logs it.
final class MintedApiKey {
  const MintedApiKey({required this.plaintext, required this.summary});

  final String plaintext;
  final ApiKeySummary summary;
}

/// The API key surface the settings UI talks to. An interface so the create
/// and revoke flows can be exercised without a worker.
abstract interface class ApiKeysClient {
  Future<List<ApiKeySummary>> listKeys();

  Future<MintedApiKey> createKey({
    required String name,
    required List<ApiKeyScope> scopes,
  });

  Future<void> revokeKey(String id);
}

final class WorkerApiKeysClient implements ApiKeysClient {
  const WorkerApiKeysClient(this._client);

  final WorkerHttpClient _client;

  @override
  Future<List<ApiKeySummary>> listKeys() async {
    final body = _body(await _client.send(method: 'GET', path: '/v1/api-keys'));
    final keys = body['keys'];
    if (keys is! List) {
      throw const WorkerResponseException('Worker returned invalid API keys');
    }
    return [
      for (final entry in keys)
        if (entry is Map<String, Object?>) _summary(entry),
    ];
  }

  @override
  Future<MintedApiKey> createKey({
    required String name,
    required List<ApiKeyScope> scopes,
  }) async {
    if (name.trim().isEmpty || scopes.isEmpty) {
      throw const WorkerResponseException(
        'A key needs a name and at least one scope',
      );
    }
    final body = _body(
      await _client.send(
        method: 'POST',
        path: '/v1/api-keys',
        body: {
          'name': name.trim(),
          'scopes': [for (final scope in scopes) scope.wireName],
        },
      ),
    );
    final plaintext = body['key'];
    final summary = body['apiKey'];
    if (plaintext is! String ||
        plaintext.isEmpty ||
        summary is! Map<String, Object?>) {
      throw const WorkerResponseException('Worker returned an invalid key');
    }
    return MintedApiKey(plaintext: plaintext, summary: _summary(summary));
  }

  @override
  Future<void> revokeKey(String id) async {
    final response = await _client.send(
      method: 'DELETE',
      path: '/v1/api-keys/$id',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = response.body;
      throw WorkerResponseException(
        body is Map<String, Object?> && body['error'] is String
            ? body['error']! as String
            : 'Could not revoke the key',
        statusCode: response.statusCode,
      );
    }
  }

  ApiKeySummary _summary(Map<String, Object?> row) {
    final id = row['id'];
    final name = row['name'];
    final prefix = row['prefix'];
    final scopes = row['scopes'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        prefix is! String ||
        scopes is! List) {
      throw const WorkerResponseException('Worker returned an invalid key');
    }
    return ApiKeySummary(
      id: id,
      name: name,
      prefix: prefix,
      scopes: [
        for (final scope in scopes)
          if (scope is String && ApiKeyScope.tryParse(scope) != null)
            ApiKeyScope.tryParse(scope)!,
      ],
      createdAt:
          _time(row['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      lastUsedAt: _time(row['lastUsedAt']),
      expiresAt: _time(row['expiresAt']),
      revokedAt: _time(row['revokedAt']),
    );
  }

  DateTime? _time(Object? value) => value is int && value > 0
      ? DateTime.fromMillisecondsSinceEpoch(value)
      : null;

  Map<String, Object?> _body(({int statusCode, Object? body}) response) {
    final body = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WorkerResponseException(
        body is Map<String, Object?> && body['error'] is String
            ? body['error']! as String
            : 'API key request failed',
        statusCode: response.statusCode,
      );
    }
    if (body is! Map<String, Object?>) {
      throw const WorkerResponseException(
        'Worker returned an invalid API key body',
      );
    }
    return body;
  }
}
