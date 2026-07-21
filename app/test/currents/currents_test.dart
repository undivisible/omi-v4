import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/currents.dart';

void main() {
  final createdAt = DateTime.utc(2026, 7, 21, 12);

  CurrentItem candidate() => CurrentItem.candidate(
    id: 'current-1',
    evidence: [
      CurrentEvidence(
        sourceId: 'source-1',
        reason: 'A deadline was stated explicitly.',
      ),
    ],
    reason: 'The deadline is tomorrow.',
    timing: CurrentTiming(
      surfaceAt: createdAt,
      expiresAt: createdAt.add(const Duration(days: 2)),
    ),
    confidence: 0.9,
    proposedNextStep: 'Draft the submission.',
    createdAt: createdAt,
  );

  test('candidate follows the surfaced, accepted, completed lifecycle', () {
    final surfaced = candidate().transitionTo(
      CurrentStatus.surfaced,
      at: createdAt.add(const Duration(minutes: 1)),
    );
    final accepted = surfaced.transitionTo(
      CurrentStatus.accepted,
      at: createdAt.add(const Duration(minutes: 2)),
      executionReference: 'execution-1',
    );
    final completed = accepted.transitionTo(
      CurrentStatus.completed,
      at: createdAt.add(const Duration(hours: 1)),
    );

    expect(completed.status, CurrentStatus.completed);
    expect(completed.executionReference, 'execution-1');
    expect(completed.isTerminal, isTrue);
  });

  test('snoozing records feedback and wakes back to surfaced', () {
    final surfaced = candidate().transitionTo(
      CurrentStatus.surfaced,
      at: createdAt.add(const Duration(minutes: 1)),
    );
    final snoozed = surfaced.transitionTo(
      CurrentStatus.snoozed,
      at: createdAt.add(const Duration(minutes: 2)),
      feedbackReference: 'feedback-1',
      snoozedUntil: createdAt.add(const Duration(hours: 2)),
    );
    final woken = snoozed.transitionTo(
      CurrentStatus.surfaced,
      at: createdAt.add(const Duration(hours: 2)),
    );

    expect(snoozed.timing.snoozedUntil, isNotNull);
    expect(woken.timing.snoozedUntil, isNull);
    expect(woken.feedbackReference, 'feedback-1');
  });

  test('invalid transitions and missing outcome references are rejected', () {
    final item = candidate().transitionTo(
      CurrentStatus.surfaced,
      at: createdAt.add(const Duration(minutes: 1)),
    );

    expect(
      () => item.transitionTo(
        CurrentStatus.completed,
        at: createdAt.add(const Duration(minutes: 2)),
      ),
      throwsStateError,
    );
    expect(
      () => item.transitionTo(
        CurrentStatus.accepted,
        at: createdAt.add(const Duration(minutes: 2)),
      ),
      throwsArgumentError,
    );
    expect(
      () => item.transitionTo(
        CurrentStatus.dismissed,
        at: createdAt.add(const Duration(minutes: 2)),
      ),
      throwsArgumentError,
    );
  });

  test('JSON round-trip preserves lifecycle data and evidence', () {
    final item = candidate()
        .transitionTo(
          CurrentStatus.surfaced,
          at: createdAt.add(const Duration(minutes: 1)),
        )
        .transitionTo(
          CurrentStatus.snoozed,
          at: createdAt.add(const Duration(minutes: 2)),
          feedbackReference: 'feedback-1',
          snoozedUntil: createdAt.add(const Duration(hours: 2)),
        );

    final decoded = CurrentItem.fromJson(item.toJson());

    expect(decoded.status, CurrentStatus.snoozed);
    expect(decoded.evidence.single.sourceId, 'source-1');
    expect(decoded.confidence, 0.9);
    expect(
      decoded.timing.snoozedUntil,
      createdAt.add(const Duration(hours: 2)),
    );
    expect(decoded.feedbackReference, 'feedback-1');
  });

  test('candidate validates evidence, confidence, and timing', () {
    expect(
      () => CurrentItem.candidate(
        id: 'current-1',
        evidence: const [],
        reason: 'Reason',
        timing: CurrentTiming(surfaceAt: createdAt),
        confidence: 0.5,
        proposedNextStep: 'Act',
        createdAt: createdAt,
      ),
      throwsArgumentError,
    );
    expect(
      () => CurrentItem.candidate(
        id: 'current-1',
        evidence: [CurrentEvidence(sourceId: 'source-1', reason: 'Reason')],
        reason: 'Reason',
        timing: CurrentTiming(surfaceAt: createdAt),
        confidence: 1.1,
        proposedNextStep: 'Act',
        createdAt: createdAt,
      ),
      throwsArgumentError,
    );
  });
}
