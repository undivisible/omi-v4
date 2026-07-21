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
