import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/features/tasks_screen.dart';
import 'package:omi/onboarding/hub_checklist.dart';

void main() {
  Map<String, Object?> card(String id, {String? sourceKind}) => {
    'id': id,
    'status': 'surfaced',
    'evidence': [
      {'sourceId': 'src-$id', 'reason': 'observed'},
    ],
    'reason': 'reason for $id',
    'timing': {'surfaceAt': '2026-07-22T08:00:00Z'},
    'confidence': 0.8,
    'proposedNextStep': 'Do the next step for $id',
    'createdAt': '2026-07-22T07:00:00Z',
    'updatedAt': '2026-07-22T07:00:00Z',
    'title': 'Task $id',
    'summary': 'Summary for $id',
    'sourceKind': ?sourceKind,
  };

  testWidgets('lists all currents with states, tags, and setup row', (
    tester,
  ) async {
    final transport = _Transport([
      card('a', sourceKind: 'telegram'),
      card('b'),
    ]);
    final controller = CurrentsController(CurrentsClient(transport));
    CurrentCard? accepted;

    await tester.pumpWidget(
      MaterialApp(
        home: TasksScreen(
          controller: controller,
          checklistStore: VolatileHubChecklistStore(setupComplete: false),
          onAccept: (task) => accepted = task,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tasks_setup_omi')), findsOneWidget);
    expect(find.text('Set up Omi.'), findsOneWidget);
    expect(find.text('Task a'), findsOneWidget);
    expect(find.text('Task b'), findsOneWidget);
    expect(find.text('SURFACED'), findsNWidgets(2));
    expect(find.text('TELEGRAM'), findsOneWidget);
    expect(find.text('Summary for a'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tasks_accept_a')));
    await tester.pump();
    expect(accepted?.item.id, 'a');

    await tester.tap(find.byKey(const Key('tasks_done_a')));
    await tester.pumpAndSettle();
    expect(transport.feedback['a'], 'dismissed');
    expect(find.text('Task a'), findsNothing);

    await tester.tap(find.byKey(const Key('tasks_reject_b')));
    await tester.pumpAndSettle();
    expect(transport.feedback['b'], 'dismissed');
    expect(find.byKey(const Key('tasks_empty')), findsOneWidget);
  });

  testWidgets('surfaces the load error inline', (tester) async {
    final controller = CurrentsController(CurrentsClient(_FailingTransport()));

    await tester.pumpWidget(
      MaterialApp(home: TasksScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tasks_error')), findsOneWidget);
  });
}

final class _Transport implements CurrentsTransport {
  _Transport(this.cards);

  final List<Map<String, Object?>> cards;
  final feedback = <String, String>{};

  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async {
    if (request.path == '/v1/currents/generate') {
      return const CurrentsResponse(statusCode: 200, body: <String, Object?>{});
    }
    if (request.path == '/v1/currents') {
      return CurrentsResponse(statusCode: 200, body: {'currents': cards});
    }
    final match = RegExp(
      r'^/v1/currents/([^/]+)/feedback$',
    ).firstMatch(request.path);
    if (match != null) {
      final id = match.group(1)!;
      feedback[id] = request.body!['kind']! as String;
      final updated = Map<String, Object?>.from(
        cards.firstWhere((value) => value['id'] == id),
      );
      updated['status'] = 'dismissed';
      updated['feedbackReference'] = 'feedback-$id';
      return CurrentsResponse(statusCode: 200, body: {'current': updated});
    }
    return const CurrentsResponse(statusCode: 404, body: {'error': 'missing'});
  }
}

final class _FailingTransport implements CurrentsTransport {
  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async =>
      const CurrentsResponse(statusCode: 500, body: {'error': 'backend down'});
}
