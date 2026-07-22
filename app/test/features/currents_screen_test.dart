import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/features/currents_screen.dart';

void main() {
  testWidgets('current cards strip markdown markers from AI text', (
    tester,
  ) async {
    final controller = CurrentsController(CurrentsClient(_Transport()));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CurrentsScreen(controller: controller)),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Finish the release'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('`'), findsNothing);
    expect(
      find.textContaining('Ship it today\nBecause you committed · Source:'),
      findsOneWidget,
    );
  });
}

final class _Transport implements CurrentsTransport {
  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async =>
      const CurrentsResponse(
        statusCode: 200,
        body: {
          'currents': [
            {
              'id': 'first',
              'status': 'surfaced',
              'evidence': [
                {'sourceId': 'memory-first', 'reason': 'Commitment'},
              ],
              'reason': '**Because** you committed',
              'timing': {'surfaceAt': '2026-07-21T12:00:00Z'},
              'confidence': 0.9,
              'proposedNextStep': 'Ship it',
              'createdAt': '2026-07-21T12:00:00Z',
              'updatedAt': '2026-07-21T12:00:00Z',
              'title': '**Finish** the `release`',
              'summary': '*Ship it* today',
            },
          ],
        },
      );
}
