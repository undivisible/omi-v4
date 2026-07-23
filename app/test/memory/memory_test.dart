import 'package:flutter_test/flutter_test.dart';
import 'package:omi/memory/memory.dart';

void main() {
  test('personal memory models preserve temporal and citation fields', () {
    final source = MemorySource.fromJson({
      'id': 'source-1',
      'tenant_id': 'tenant-1',
      'person_id': 'person-1',
      'revision': 1,
      'kind': 'user_correction',
      'content': 'I work at Example Corp.',
      'captured_at': 100,
      'recorded_at': 110,
      'deleted_at': null,
    });
    final claim = TemporalClaim.fromJson({
      'id': 'claim-1',
      'tenant_id': 'tenant-1',
      'person_id': 'person-1',
      'subject': 'person-1',
      'predicate': 'employer',
      'value': 'Example Corp',
      'valid_time': {'from': 100, 'until': null},
      'recorded_time': {'from': 110, 'until': null},
      'status': 'accepted',
    });
    final pack = RetrievalPack.fromJson({
      'query': 'Where do I work?',
      'items': [
        {
          'memory': {'kind': 'claim', 'id': 'claim-1'},
          'excerpt': 'Works at Example Corp',
          'relevance_basis_points': 9500,
          'evidence_ids': ['evidence-1'],
        },
      ],
      'gaps': <String>[],
    });

    expect(source.toJson()['kind'], 'user_correction');
    expect(claim.toJson()['valid_time'], {'from': 100, 'until': null});
    expect(pack.toJson()['items'], [
      {
        'memory': {'kind': 'claim', 'id': 'claim-1'},
        'excerpt': 'Works at Example Corp',
        'relevance_basis_points': 9500,
        'evidence_ids': ['evidence-1'],
      },
    ]);
  });

  test(
    'client sends bounded retrieval request and decodes citations',
    () async {
      final transport = _FakeTransport(
        const MemoryResponse(
          statusCode: 200,
          body: {
            'query': 'Where do I work?',
            'items': [
              {
                'memory': {'kind': 'profile_entry', 'id': 'profile-1'},
                'excerpt': 'Employer: Example Corp',
                'relevance_basis_points': 9000,
                'evidence_ids': ['evidence-1'],
              },
            ],
            'gaps': <String>[],
          },
        ),
      );

      final pack = await MemoryClient(
        transport,
      ).retrieve(query: 'Where do I work?', limit: 8);

      expect(transport.lastRequest?.path, '/v1/memory/retrieve');
      expect(transport.lastRequest?.query, {
        'q': 'Where do I work?',
        'limit': '8',
      });
      expect(pack.items.single.evidenceIds, ['evidence-1']);
      expect(pack.items.single.memory.kind, MemoryKind.profileEntry);
    },
  );

  test('client exposes API, decoding, and query validation failures', () async {
    final apiClient = MemoryClient(
      _FakeTransport(
        const MemoryResponse(statusCode: 409, body: {'error': 'Conflict'}),
      ),
    );
    final decodingClient = MemoryClient(
      _FakeTransport(const MemoryResponse(statusCode: 200, body: [])),
    );

    await expectLater(
      apiClient.retrieve(query: 'work'),
      throwsA(
        isA<MemoryApiException>()
            .having((error) => error.statusCode, 'statusCode', 409)
            .having((error) => error.message, 'message', 'Conflict'),
      ),
    );
    await expectLater(
      decodingClient.retrieve(query: 'work'),
      throwsA(isA<MemoryDecodingException>()),
    );
    await expectLater(
      decodingClient.retrieve(query: ' '),
      throwsA(isA<MemoryDecodingException>()),
    );
    expect(
      () => RetrievalItem.fromJson({
        'memory': {'kind': 'claim', 'id': 'claim-1'},
        'excerpt': 'Uncited claim',
        'relevance_basis_points': 9000,
        'evidence_ids': <String>[],
      }),
      throwsA(isA<MemoryFormatException>()),
    );
  });

  test('time and byte ranges reject inverted or empty spans', () {
    expect(
      () => TimeRange.fromJson({'from': 100, 'until': 100}),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(
      () => TimeRange.fromJson({'from': 100, 'until': 99}),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(
      () => TimeRange.fromJson({'from': 100, 'until': '101'}),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(TimeRange.fromJson({'from': 100, 'until': 101}).toJson(), {
      'from': 100,
      'until': 101,
    });
    expect(TimeRange.fromJson({'from': 100, 'until': null}).until, isNull);

    expect(
      () => ByteRange.fromJson({'start': -1, 'end': 4}),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(
      () => ByteRange.fromJson({'start': 4, 'end': 4}),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(ByteRange.fromJson({'start': 0, 'end': 4}).toJson(), {
      'start': 0,
      'end': 4,
    });
  });

  test('field decoding rejects wrong shapes with a named message', () {
    expect(
      () => MemorySource.fromJson({...sourceJson(), 'id': 7}),
      throwsA(
        isA<MemoryFormatException>().having(
          (error) => error.message,
          'message',
          'id must be a string',
        ),
      ),
    );
    expect(
      () => MemorySource.fromJson({...sourceJson(), 'revision': '1'}),
      throwsA(
        isA<MemoryFormatException>().having(
          (error) => error.message,
          'message',
          'revision must be an integer',
        ),
      ),
    );
    expect(
      () => MemorySource.fromJson({...sourceJson(), 'kind': 'telepathy'}),
      throwsA(
        isA<MemoryFormatException>().having(
          (error) => error.message,
          'message',
          'Unknown enum value: telepathy',
        ),
      ),
    );
    expect(
      () => TemporalClaim.fromJson({...claimJson(), 'valid_time': 'now'}),
      throwsA(
        isA<MemoryFormatException>().having(
          (error) => error.message,
          'message',
          'valid_time must be an object',
        ),
      ),
    );
    expect(
      () => Evidence.fromJson({...evidenceJson(), 'byte_range': 'nope'}),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(
      const MemoryFormatException('bad').toString(),
      'MemoryFormatException: bad',
    );
  });

  test('multi-word enum names travel over the wire in snake case', () {
    final entry = ProfileEntry.fromJson(profileJson());
    final reference = MemoryReference.fromJson({
      'kind': 'daily_review',
      'id': 'review-1',
    });

    expect(entry.stability, ProfileStability.current);
    expect(entry.toJson()['stability'], 'current');
    expect(reference.kind, MemoryKind.dailyReview);
    expect(reference.toJson()['kind'], 'daily_review');
    expect(
      MemorySource.fromJson({
        ...sourceJson(),
        'kind': 'user_correction',
      }).toJson()['kind'],
      'user_correction',
    );
  });

  test('every record round trips through json unchanged', () {
    expect(MemorySource.fromJson(sourceJson()).toJson(), sourceJson());
    expect(Evidence.fromJson(evidenceJson()).toJson(), evidenceJson());
    expect(TemporalClaim.fromJson(claimJson()).toJson(), claimJson());
    expect(ProfileEntry.fromJson(profileJson()).toJson(), profileJson());
    expect(DailyReview.fromJson(reviewJson()).toJson(), reviewJson());
    expect(
      ClaimEvidence.fromJson(claimEvidenceJson()).toJson(),
      claimEvidenceJson(),
    );
  });

  test('citations and relevance stay inside their bounds', () {
    expect(
      () => DailyReview.fromJson({...reviewJson(), 'evidence_ids': <String>[]}),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(
      () => DailyReview.fromJson({
        ...reviewJson(),
        'evidence_ids': ['  '],
      }),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(
      () => DailyReview.fromJson({...reviewJson(), 'evidence_ids': 'evidence'}),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(
      () => DailyReview.fromJson({
        ...reviewJson(),
        'evidence_ids': [7],
      }),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(
      () => RetrievalItem.fromJson({
        ...retrievalItemJson(),
        'relevance_basis_points': 10001,
      }),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(
      () => RetrievalItem.fromJson({
        ...retrievalItemJson(),
        'relevance_basis_points': -1,
      }),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(
      RetrievalItem.fromJson({
        ...retrievalItemJson(),
        'relevance_basis_points': 10000,
      }).relevanceBasisPoints,
      10000,
    );
  });

  test('retrieval packs reject malformed collections', () {
    expect(
      () => RetrievalPack.fromJson({
        'query': 'work',
        'items': 'none',
        'gaps': <String>[],
      }),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(
      () => RetrievalPack.fromJson({
        'query': 'work',
        'items': ['not-an-object'],
        'gaps': <String>[],
      }),
      throwsA(isA<MemoryFormatException>()),
    );
    expect(
      () => RetrievalPack.fromJson({
        'query': 'work',
        'items': <Object?>[],
        'gaps': [1],
      }),
      throwsA(isA<MemoryFormatException>()),
    );

    final empty = RetrievalPack.fromJson({
      'query': 'work',
      'items': <Object?>[],
      'gaps': ['no employer on file'],
    });
    expect(empty.items, isEmpty);
    expect(empty.toJson()['gaps'], ['no employer on file']);
  });

  test('writes post their record and decode the stored copy', () async {
    final source = MemorySource.fromJson(sourceJson());
    final transport = _FakeTransport(
      MemoryResponse(statusCode: 201, body: sourceJson()),
    );

    final stored = await MemoryClient(transport).createSource(source);

    expect(transport.lastRequest?.method, MemoryHttpMethod.post);
    expect(transport.lastRequest?.path, '/v1/memory/sources');
    expect(transport.lastRequest?.body, sourceJson());
    expect(stored.toJson(), sourceJson());
  });

  test('each write targets its own endpoint', () async {
    Future<String> pathFor(
      Future<Object?> Function(MemoryClient) call,
      JsonMap response,
    ) async {
      final transport = _FakeTransport(
        MemoryResponse(statusCode: 200, body: response),
      );
      await call(MemoryClient(transport));
      return transport.lastRequest!.path;
    }

    expect(
      await pathFor(
        (client) => client.createEvidence(Evidence.fromJson(evidenceJson())),
        evidenceJson(),
      ),
      '/v1/memory/evidence',
    );
    expect(
      await pathFor(
        (client) => client.proposeClaim(TemporalClaim.fromJson(claimJson())),
        claimJson(),
      ),
      '/v1/memory/claims',
    );
    expect(
      await pathFor(
        (client) =>
            client.saveProfileEntry(ProfileEntry.fromJson(profileJson())),
        profileJson(),
      ),
      '/v1/memory/profile',
    );
    expect(
      await pathFor(
        (client) => client.saveDailyReview(DailyReview.fromJson(reviewJson())),
        reviewJson(),
      ),
      '/v1/memory/reviews',
    );
  });

  test('retrieval limits are clamped before a request is made', () async {
    final transport = _FakeTransport(
      const MemoryResponse(statusCode: 200, body: {}),
    );
    final client = MemoryClient(transport);

    await expectLater(
      client.retrieve(query: 'work', limit: 0),
      throwsA(isA<MemoryDecodingException>()),
    );
    await expectLater(
      client.retrieve(query: 'work', limit: 51),
      throwsA(isA<MemoryDecodingException>()),
    );
    expect(transport.lastRequest, isNull);
  });

  test('a server that overruns the limit is not trusted', () async {
    final transport = _FakeTransport(
      MemoryResponse(
        statusCode: 200,
        body: {
          'query': 'work',
          'items': [retrievalItemJson(), retrievalItemJson()],
          'gaps': <String>[],
        },
      ),
    );

    await expectLater(
      MemoryClient(transport).retrieve(query: 'work', limit: 1),
      throwsA(
        isA<MemoryDecodingException>().having(
          (error) => error.message,
          'message',
          'retrieval returned 2 items for a limit of 1',
        ),
      ),
    );
  });

  test(
    'transport failures are wrapped and client failures pass through',
    () async {
      final broken = MemoryClient(
        _ThrowingTransport(const SocketFailure('connection reset')),
      );
      final rejecting = MemoryClient(
        _ThrowingTransport(const MemoryApiException(401, 'Unauthorized')),
      );

      await expectLater(
        broken.retrieve(query: 'work'),
        throwsA(
          isA<MemoryTransportException>().having(
            (error) => error.message,
            'message',
            contains('connection reset'),
          ),
        ),
      );
      await expectLater(
        rejecting.retrieve(query: 'work'),
        throwsA(
          isA<MemoryApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect(
        const MemoryTransportException('down').toString(),
        contains('down'),
      );
    },
  );

  test('an error status without an error string still fails cleanly', () async {
    final client = MemoryClient(
      _FakeTransport(
        const MemoryResponse(statusCode: 503, body: 'gateway is down'),
      ),
    );

    await expectLater(
      client.retrieve(query: 'work'),
      throwsA(
        isA<MemoryApiException>()
            .having((error) => error.statusCode, 'statusCode', 503)
            .having(
              (error) => error.message,
              'message',
              'Memory request failed',
            ),
      ),
    );
  });

  test('a success body that is not an object is a decoding failure', () async {
    final client = MemoryClient(
      _FakeTransport(const MemoryResponse(statusCode: 200)),
    );

    await expectLater(
      client.retrieve(query: 'work'),
      throwsA(
        isA<MemoryDecodingException>().having(
          (error) => error.message,
          'message',
          'response must be an object',
        ),
      ),
    );
  });
}

JsonMap sourceJson() => {
  'id': 'source-1',
  'tenant_id': 'tenant-1',
  'person_id': 'person-1',
  'revision': 1,
  'kind': 'conversation',
  'content': 'I work at Example Corp.',
  'captured_at': 100,
  'recorded_at': 110,
  'deleted_at': null,
};

JsonMap evidenceJson() => {
  'id': 'evidence-1',
  'tenant_id': 'tenant-1',
  'person_id': 'person-1',
  'source_id': 'source-1',
  'source_revision': 1,
  'quote': 'I work at Example Corp.',
  'byte_range': {'start': 0, 'end': 5},
  'recorded_at': 110,
};

JsonMap claimJson() => {
  'id': 'claim-1',
  'tenant_id': 'tenant-1',
  'person_id': 'person-1',
  'subject': 'person-1',
  'predicate': 'employer',
  'value': 'Example Corp',
  'valid_time': {'from': 100, 'until': null},
  'recorded_time': {'from': 110, 'until': null},
  'status': 'accepted',
};

JsonMap claimEvidenceJson() => {
  'tenant_id': 'tenant-1',
  'person_id': 'person-1',
  'claim_id': 'claim-1',
  'evidence_id': 'evidence-1',
  'relation': 'supports',
  'confidence_basis_points': 9000,
};

JsonMap profileJson() => {
  'id': 'profile-1',
  'tenant_id': 'tenant-1',
  'person_id': 'person-1',
  'key': 'employer',
  'value': 'Example Corp',
  'stability': 'current',
  'claim_id': 'claim-1',
  'recorded_at': 110,
};

JsonMap reviewJson() => {
  'id': 'review-1',
  'tenant_id': 'tenant-1',
  'person_id': 'person-1',
  'day': '2026-07-23',
  'summary': 'Shipped the memory client.',
  'evidence_ids': ['evidence-1'],
  'recorded_at': 110,
};

JsonMap retrievalItemJson() => {
  'memory': {'kind': 'claim', 'id': 'claim-1'},
  'excerpt': 'Works at Example Corp',
  'relevance_basis_points': 9000,
  'evidence_ids': ['evidence-1'],
};

final class SocketFailure implements Exception {
  const SocketFailure(this.message);

  final String message;

  @override
  String toString() => 'SocketFailure: $message';
}

final class _FakeTransport implements MemoryTransport {
  _FakeTransport(this.response);

  final MemoryResponse response;
  MemoryRequest? lastRequest;

  @override
  Future<MemoryResponse> send(MemoryRequest request) async {
    lastRequest = request;
    return response;
  }
}

final class _ThrowingTransport implements MemoryTransport {
  const _ThrowingTransport(this.error);

  final Object error;

  @override
  Future<MemoryResponse> send(MemoryRequest request) async => throw error;
}
