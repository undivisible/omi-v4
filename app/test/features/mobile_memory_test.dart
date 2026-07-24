import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/mobile_memory_screen.dart';
import 'package:omi/memory/memory.dart';

void main() {
  testWidgets('search renders cited results from the memory client', (
    tester,
  ) async {
    final transport = _FakeMemoryTransport();
    await tester.pumpWidget(
      MaterialApp(home: MobileMemoryScreen(memory: MemoryClient(transport))),
    );

    await tester.enterText(
      find.byKey(const Key('memory_search_field')),
      'handoff',
    );
    await tester.tap(find.byKey(const Key('memory_search_submit')));
    await tester.pumpAndSettle();

    expect(transport.lastRetrieveQuery, 'handoff');
    expect(find.byKey(const Key('memory_result_0')), findsOneWidget);
    expect(find.text('Sam is waiting on the handoff.'), findsOneWidget);
    expect(find.textContaining('92% match'), findsOneWidget);
  });

  testWidgets('empty search reports no matches', (tester) async {
    final transport = _FakeMemoryTransport(items: const []);
    await tester.pumpWidget(
      MaterialApp(home: MobileMemoryScreen(memory: MemoryClient(transport))),
    );

    await tester.enterText(
      find.byKey(const Key('memory_search_field')),
      'nothing',
    );
    await tester.tap(find.byKey(const Key('memory_search_submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('memory_search_empty')), findsOneWidget);
  });

  testWidgets('remember writes a memory through the client', (tester) async {
    final transport = _FakeMemoryTransport();
    await tester.pumpWidget(
      MaterialApp(home: MobileMemoryScreen(memory: MemoryClient(transport))),
    );

    await tester.enterText(
      find.byKey(const Key('memory_create_field')),
      'I take my coffee black.',
    );
    await tester.tap(find.byKey(const Key('memory_create_submit')));
    await tester.pumpAndSettle();

    expect(transport.createdContent, 'I take my coffee black.');
    expect(find.byKey(const Key('memory_create_done')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('memory_create_field')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('a failing client explains itself instead of blanking', (
    tester,
  ) async {
    final transport = _FakeMemoryTransport(fail: true);
    await tester.pumpWidget(
      MaterialApp(home: MobileMemoryScreen(memory: MemoryClient(transport))),
    );

    await tester.enterText(
      find.byKey(const Key('memory_search_field')),
      'anything',
    );
    await tester.tap(find.byKey(const Key('memory_search_submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('memory_search_error')), findsOneWidget);
  });
}

final class _FakeMemoryTransport implements MemoryTransport {
  _FakeMemoryTransport({this.items = _defaultItems, this.fail = false});

  final List<Map<String, Object?>> items;
  final bool fail;
  String? lastRetrieveQuery;
  String? createdContent;

  static const _defaultItems = [
    {
      'memory': {'kind': 'profile_entry', 'id': 'mem-1'},
      'excerpt': 'Sam is waiting on the handoff.',
      'relevance_basis_points': 9200,
      'evidence_ids': ['ev-1'],
    },
  ];

  @override
  Future<MemoryResponse> send(MemoryRequest request) async {
    if (fail) {
      return const MemoryResponse(
        statusCode: 503,
        body: {'error': 'Memory backend unreachable'},
      );
    }
    if (request.path == '/v1/memory/retrieve') {
      lastRetrieveQuery = request.query['q'];
      return MemoryResponse(
        statusCode: 200,
        body: {'query': request.query['q'], 'items': items, 'gaps': const []},
      );
    }
    if (request.path == '/v1/memories') {
      createdContent = request.body!['content'] as String;
      return const MemoryResponse(
        statusCode: 201,
        body: {'id': 'p-1', 'sourceId': 's-1', 'claimId': 'c-1'},
      );
    }
    return const MemoryResponse(statusCode: 404, body: {'error': 'missing'});
  }
}
