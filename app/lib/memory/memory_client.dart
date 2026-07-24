import 'memory_models.dart';

enum MemoryHttpMethod { get, post, put, delete }

final class MemoryRequest {
  const MemoryRequest({
    required this.method,
    required this.path,
    this.query = const {},
    this.body,
  });

  final MemoryHttpMethod method;
  final String path;
  final Map<String, String> query;
  final JsonMap? body;
}

final class MemoryResponse {
  const MemoryResponse({required this.statusCode, this.body});

  final int statusCode;
  final Object? body;
}

abstract interface class MemoryTransport {
  Future<MemoryResponse> send(MemoryRequest request);
}

sealed class MemoryClientException implements Exception {
  const MemoryClientException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class MemoryTransportException extends MemoryClientException {
  const MemoryTransportException(super.message);
}

final class MemoryApiException extends MemoryClientException {
  const MemoryApiException(this.statusCode, super.message);

  final int statusCode;
}

final class MemoryDecodingException extends MemoryClientException {
  const MemoryDecodingException(super.message);
}

final class MemoryClient {
  const MemoryClient(this._transport);

  final MemoryTransport _transport;

  Future<MemorySource> createSource(MemorySource source) =>
      _write('/v1/memory/sources', source.toJson(), MemorySource.fromJson);

  Future<Evidence> createEvidence(Evidence evidence) =>
      _write('/v1/memory/evidence', evidence.toJson(), Evidence.fromJson);

  Future<TemporalClaim> proposeClaim(TemporalClaim claim) =>
      _write('/v1/memory/claims', claim.toJson(), TemporalClaim.fromJson);

  Future<ProfileEntry> saveProfileEntry(ProfileEntry entry) =>
      _write('/v1/memory/profile', entry.toJson(), ProfileEntry.fromJson);

  Future<DailyReview> saveDailyReview(DailyReview review) =>
      _write('/v1/memory/reviews', review.toJson(), DailyReview.fromJson);

  /// The account's daily and nightly digests, newest first, from
  /// `GET /v1/memory/daily-reviews`. The endpoint wraps the rows in a
  /// `{"reviews": [...]}` envelope; each row carries its `kind`, `body`, and
  /// `localDate`.
  Future<List<MemoryDigest>> listDailyReviews() async {
    final response = await _send(
      MemoryRequest(
        method: MemoryHttpMethod.get,
        path: '/v1/memory/daily-reviews',
      ),
    );
    final body = response.body;
    if (body is! Map<String, Object?>) {
      throw const MemoryDecodingException('daily-reviews must be an object');
    }
    final reviews = body['reviews'];
    if (reviews is! List) {
      throw const MemoryDecodingException('daily-reviews must carry a list');
    }
    try {
      return [
        for (final review in reviews)
          if (review is Map<String, Object?>) MemoryDigest.fromJson(review),
      ];
    } on MemoryFormatException catch (error) {
      throw MemoryDecodingException(error.message);
    } on TypeError catch (error) {
      throw MemoryDecodingException(error.toString());
    }
  }

  Future<CreatedMemory> createMemory(String content) async {
    if (content.trim().isEmpty) {
      throw const MemoryDecodingException('content must not be empty');
    }
    final response = await _send(
      MemoryRequest(
        method: MemoryHttpMethod.post,
        path: '/v1/memories',
        body: {'content': content},
      ),
    );
    return _decode(response.body, CreatedMemory.fromJson);
  }

  Future<RetrievalPack> retrieve({
    required String query,
    int limit = 12,
  }) async {
    if (query.trim().isEmpty) {
      throw const MemoryDecodingException('query must not be empty');
    }
    if (limit < 1 || limit > 50) {
      throw const MemoryDecodingException('limit must be between 1 and 50');
    }
    final response = await _send(
      MemoryRequest(
        method: MemoryHttpMethod.get,
        path: '/v1/memory/retrieve',
        query: {'q': query, 'limit': '$limit'},
      ),
    );
    final pack = _decode(response.body, RetrievalPack.fromJson);
    if (pack.items.length > limit) {
      throw MemoryDecodingException(
        'retrieval returned ${pack.items.length} items for a limit of $limit',
      );
    }
    return pack;
  }

  Future<T> _write<T>(
    String path,
    JsonMap body,
    T Function(JsonMap) decode,
  ) async {
    final response = await _send(
      MemoryRequest(method: MemoryHttpMethod.post, path: path, body: body),
    );
    return _decode(response.body, decode);
  }

  Future<MemoryResponse> _send(MemoryRequest request) async {
    final MemoryResponse response;
    try {
      response = await _transport.send(request);
    } on MemoryClientException {
      rethrow;
    } catch (error) {
      throw MemoryTransportException(error.toString());
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = response.body;
      final message = body is Map && body['error'] is String
          ? body['error']! as String
          : 'Memory request failed';
      throw MemoryApiException(response.statusCode, message);
    }
    return response;
  }

  T _decode<T>(Object? value, T Function(JsonMap) decode) {
    try {
      if (value is! Map<String, Object?>) {
        throw const MemoryFormatException('response must be an object');
      }
      return decode(value);
    } on MemoryFormatException catch (error) {
      throw MemoryDecodingException(error.message);
    } on TypeError catch (error) {
      throw MemoryDecodingException(error.toString());
    }
  }
}
