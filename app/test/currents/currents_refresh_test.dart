import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/currents.dart';

void main() {
  test('refresh decodes mixed content kinds', () async {
    final transport = _RefreshTransport();
    final client = CurrentsClient(transport);
    final outcome = await client.refresh();
    expect(outcome.refreshed, isTrue);
    expect(outcome.items, hasLength(3));
    expect(outcome.items[0].contentKind, CurrentContentKind.agentAction);
    expect(outcome.items[1].contentKind, CurrentContentKind.humanAction);
    expect(outcome.items[2].contentKind, CurrentContentKind.awareness);
    expect(currentContentKindLabel(outcome.items[0].contentKind), 'Omi');
  });
}

final class _RefreshTransport implements CurrentsTransport {
  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async {
    expect(request.path, '/v1/currents/refresh');
    return CurrentsResponse(
      statusCode: 200,
      body: {
        'refreshed': true,
        'reason': 'new_memory',
        'currents': [
          _current('agent_action'),
          _current('human_action'),
          _current('awareness'),
        ],
      },
    );
  }
}

Map<String, Object?> _current(String contentKind) => {
  'id': 'current-$contentKind',
  'title': 'Title for $contentKind',
  'summary': 'Summary',
  'contentKind': contentKind,
  'status': 'surfaced',
  'evidence': [
    {'sourceId': 'source-1', 'reason': 'Because'},
  ],
  'reason': 'Because',
  'confidence': 0.8,
  'proposedNextStep': 'Next',
  'timing': {
    'surfaceAt': '2026-07-21T12:00:00.000Z',
    'expiresAt': null,
    'snoozedUntil': null,
  },
  'createdAt': '2026-07-21T12:00:00.000Z',
  'updatedAt': '2026-07-21T12:00:00.000Z',
};
