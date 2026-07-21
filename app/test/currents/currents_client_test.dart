import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/currents.dart';

void main() {
  test(
    'decodes cited Currents and sends feedback and action handoff requests',
    () async {
      final transport = _Transport();
      final client = CurrentsClient(transport);
      await client.generate();
      expect(transport.requests.single.path, '/v1/currents/generate');
      final items = await client.list();
      expect(items.single.title, 'Ship release');
      expect(items.single.item.evidence.single.sourceId, 'conversation-1');

      await client.feedback('current-1', CurrentStatus.dismissed);
      expect(transport.requests.last.path, '/v1/currents/current-1/feedback');
      expect(transport.requests.last.body, {'kind': 'dismissed'});

      final handoff = await client.accept('current-1');
      expect(handoff.executionId, 'execution-1');
      expect(handoff.instruction, 'Review release checklist');
      await client.approve(handoff);
      expect(transport.requests.last.path, endsWith('/approve'));
      await client.recordOutcome(
        handoff,
        CurrentExecutionOutcome.succeeded,
        'Done',
      );
      expect(transport.requests.last.body, {
        'state': 'succeeded',
        'detail': 'Done',
      });
    },
  );

  test(
    'controller removes feedback items without rewriting cited memory',
    () async {
      final controller = CurrentsController(CurrentsClient(_Transport()));
      await controller.load();
      expect(controller.loading, isFalse);
      expect(controller.items, hasLength(1));
      await controller.dismiss('current-1');
      expect(controller.items, isEmpty);
    },
  );
}

final class _Transport implements CurrentsTransport {
  final requests = <CurrentsRequest>[];

  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async {
    requests.add(request);
    if (request.path.endsWith('/generate')) {
      return const CurrentsResponse(statusCode: 200, body: {'current': null});
    }
    if (request.path.endsWith('/accept')) {
      return const CurrentsResponse(
        statusCode: 201,
        body: {
          'executionId': 'execution-1',
          'approvalNonce': 'nonce-1',
          'action': {
            'kind': 'review',
            'instruction': 'Review release checklist',
          },
          'state': 'awaiting_approval',
        },
      );
    }
    if (request.path.endsWith('/feedback')) {
      return CurrentsResponse(
        statusCode: 200,
        body: {
          'current': _current('dismissed', feedbackReference: 'feedback-1'),
        },
      );
    }
    if (request.path.endsWith('/approve') ||
        request.path.endsWith('/outcome') ||
        request.path.endsWith('/reject')) {
      return const CurrentsResponse(statusCode: 200, body: {'ok': true});
    }
    return CurrentsResponse(
      statusCode: 200,
      body: {
        'currents': [_current('surfaced')],
      },
    );
  }
}

Map<String, Object?> _current(String status, {String? feedbackReference}) => {
  'id': 'current-1',
  'title': 'Ship release',
  'summary': 'The release checklist is unfinished.',
  'status': status,
  'evidence': [
    {'sourceId': 'conversation-1', 'reason': 'Cited commitment'},
  ],
  'reason': 'Cited commitment',
  'confidence': 0.9,
  'proposedNextStep': 'Review release checklist',
  'timing': {
    'surfaceAt': '2026-07-21T12:00:00.000Z',
    'expiresAt': null,
    'snoozedUntil': null,
  },
  'feedbackReference': feedbackReference,
  'executionReference': null,
  'createdAt': '2026-07-21T12:00:00.000Z',
  'updatedAt': '2026-07-21T12:00:00.000Z',
};
