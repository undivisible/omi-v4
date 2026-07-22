import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/currents.dart';

const _actionHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _receiptToken = '0123456789012345678901234567890123456789012';

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
      final receipt = await client.approve(
        handoff,
        subject: 'user-1',
        proposalId: 'proposal-1',
        operationId: 'operation-1',
        actionHash: _actionHash,
        risk: 'external',
      );
      expect(transport.requests.last.path, endsWith('/approve'));
      expect(transport.requests.last.body, {
        'approvalNonce': 'nonce-1',
        'proposalId': 'proposal-1',
        'operationId': 'operation-1',
        'actionHash': _actionHash,
        'risk': 'external',
        'generation': 7,
      });
      expect(receipt.receiptId, 'receipt-1');
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

  test('controller coalesces overlapping refreshes', () async {
    final transport = _Transport()..pauseGenerate = Completer<void>();
    final controller = CurrentsController(CurrentsClient(transport));

    final first = controller.load();
    final second = controller.load();
    var secondCompleted = false;
    second.then((_) => secondCompleted = true);
    await Future<void>.delayed(Duration.zero);

    expect(secondCompleted, isFalse);
    transport.pauseGenerate!.complete();
    await Future.wait([first, second]);
    expect(secondCompleted, isTrue);

    expect(
      transport.requests.where((request) => request.path.endsWith('/generate')),
      hasLength(1),
    );
  });

  test('rejects a mismatched approval receipt', () async {
    final transport = _Transport()..receiptSubject = 'other-user';
    final client = CurrentsClient(transport);
    final handoff = await client.accept('current-1');

    await expectLater(
      client.approve(
        handoff,
        subject: 'user-1',
        proposalId: 'proposal-1',
        operationId: 'operation-1',
        actionHash: _actionHash,
        risk: 'external',
      ),
      throwsA(isA<CurrentsClientException>()),
    );
  });

  test(
    'serializes exact terminal outcome replays without effect retry',
    () async {
      final transport = _Transport();
      final client = CurrentsClient(transport);
      const handoff = CurrentActionHandoff(
        executionId: 'execution-1',
        approvalNonce: 'nonce-1',
        instruction: 'Invoke Save',
        policyGeneration: 7,
      );
      for (final outcomeCase in <(CurrentExecutionOutcome, String)>[
        (
          CurrentExecutionOutcome.cancelledBeforeEffect,
          'cancelled_before_effect',
        ),
        (CurrentExecutionOutcome.expiredBeforeEffect, 'expired_before_effect'),
        (CurrentExecutionOutcome.outcomeUnknown, 'outcome_unknown'),
      ]) {
        final first = client.recordOutcome(handoff, outcomeCase.$1, 'Terminal');
        await first;
        final second = client.recordOutcome(
          handoff,
          outcomeCase.$1,
          'Terminal',
        );
        await second;
        expect(transport.requests[transport.requests.length - 2].body, {
          'state': outcomeCase.$2,
          'detail': 'Terminal',
        });
        expect(
          transport.requests.last.body,
          transport.requests[transport.requests.length - 2].body,
        );
      }
    },
  );
}

final class _Transport implements CurrentsTransport {
  final requests = <CurrentsRequest>[];
  Completer<void>? pauseGenerate;
  String receiptSubject = 'user-1';

  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async {
    requests.add(request);
    if (request.path.endsWith('/generate')) {
      await pauseGenerate?.future;
      return const CurrentsResponse(statusCode: 200, body: {'current': null});
    }
    if (request.path.endsWith('/accept')) {
      return CurrentsResponse(
        statusCode: 201,
        body: {
          'executionId': 'execution-1',
          'approvalNonce': 'nonce-1',
          'policyGeneration': 7,
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
    if (request.path.endsWith('/approve')) {
      return CurrentsResponse(
        statusCode: 200,
        body: {
          'receipt': {
            'version': 'omi-current-authority-v1',
            'receiptId': 'receipt-1',
            'receiptToken': _receiptToken,
            'subject': receiptSubject,
            'proposalId': 'proposal-1',
            'operationId': 'operation-1',
            'actionHash': _actionHash,
            'policyGeneration': 7,
            'risk': 'external',
            'issuedAtMs': 4102444700000,
            'expiresAtMs': 4102444800000,
          },
        },
      );
    }
    if (request.path.endsWith('/reject')) {
      return const CurrentsResponse(statusCode: 200, body: {'ok': true});
    }
    if (request.path.endsWith('/outcome')) {
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
