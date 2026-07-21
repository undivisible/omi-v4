import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/memory/memory.dart';
import 'package:omi/native/generated/signals/signals.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  test('ignores stale search results', () async {
    final hub = _FakeNativeHub();
    final controller = NativeMemoryController(
      hub: hub,
      events: hub.events,
      requestId: _ids(['first', 'second']),
    );

    controller.search('old');
    controller.search('new');
    hub.add(
      const NativeEventMemorySearchResults(
        value: MemorySearchResults(
          requestId: 'first',
          query: 'old',
          items: [],
          gaps: ['stale'],
        ),
      ),
    );
    hub.add(
      const NativeEventMemorySearchResults(
        value: MemorySearchResults(
          requestId: 'second',
          query: 'new',
          items: [
            MemorySearchItem(
              kind: 'claim',
              id: 'claim-1',
              excerpt: 'Current result',
              relevanceBasisPoints: 9000,
              evidenceIds: ['evidence-1'],
            ),
          ],
          gaps: [],
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.loading, isFalse);
    expect(controller.items.single.id, 'claim-1');
    expect(controller.gaps, isEmpty);
    controller.dispose();
    await hub.close();
  });

  test('refreshes the active query after a confirmed correction', () async {
    final hub = _FakeNativeHub();
    final controller = NativeMemoryController(
      hub: hub,
      events: hub.events,
      requestId: _ids(['search', 'correct', 'refresh']),
      now: () => DateTime.fromMillisecondsSinceEpoch(42),
    );

    controller.search('family');
    controller.correct(claimId: 'claim-1', text: 'Updated', value: 'Updated');
    expect(hub.correction?.occurredAtMs, 42);
    hub.add(
      const NativeEventMemoryCorrected(
        value: MemoryCorrected(
          requestId: 'correct',
          sourceId: 'source-2',
          evidenceId: 'evidence-2',
          claimId: 'claim-2',
          supersededClaimId: 'claim-1',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(hub.searches.last, (requestId: 'refresh', query: 'family'));
    controller.dispose();
    await hub.close();
  });

  test('surfaces matching native errors', () async {
    final hub = _FakeNativeHub();
    final controller = NativeMemoryController(
      hub: hub,
      events: hub.events,
      requestId: _ids(['search']),
    );

    controller.search('profile');
    hub.add(
      const NativeEventError(
        value: NativeError(
          requestId: 'search',
          code: 'memory_search_failed',
          message: 'Database unavailable',
          retryable: true,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.loading, isFalse);
    expect(controller.error, 'Database unavailable');
    controller.dispose();
    await hub.close();
  });
}

String Function() _ids(List<String> values) {
  final iterator = values.iterator;
  return () {
    iterator.moveNext();
    return iterator.current;
  };
}

final class _FakeNativeHub implements NativeHub {
  final _events = StreamController<NativeEvent>.broadcast(sync: true);
  final searches = <({String requestId, String query})>[];
  ({String requestId, int occurredAtMs})? correction;

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  void add(NativeEvent event) => _events.add(event);

  Future<void> close() => _events.close();

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  }) => searches.add((requestId: requestId, query: query));

  @override
  void correctMemory({
    required String requestId,
    required String claimId,
    required String text,
    required String value,
    required int occurredAtMs,
    required int recordedAtMs,
  }) => correction = (requestId: requestId, occurredAtMs: occurredAtMs);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
