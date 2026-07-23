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

  test('an empty query is not sent to the hub', () async {
    final hub = _FakeNativeHub();
    final controller = NativeMemoryController(
      hub: hub,
      events: hub.events,
      requestId: _ids(['unused']),
    );

    controller.search('   ');

    expect(hub.searches, isEmpty);
    expect(controller.query, 'profile');
    expect(controller.loading, isFalse);
    controller.dispose();
    await hub.close();
  });

  test('a query is trimmed before it becomes the active one', () async {
    final hub = _FakeNativeHub();
    final controller = NativeMemoryController(
      hub: hub,
      events: hub.events,
      requestId: _ids(['search']),
    );

    controller.search('  where do I work?  ');

    expect(controller.query, 'where do I work?');
    expect(hub.searches.single.query, 'where do I work?');
    expect(controller.loading, isTrue);
    controller.dispose();
    await hub.close();
  });

  test('an unusable correction is refused before any request', () async {
    final hub = _FakeNativeHub();
    final controller = NativeMemoryController(
      hub: hub,
      events: hub.events,
      requestId: _ids(['unused']),
    );

    controller
      ..correct(claimId: 'claim-1', text: '  ', value: 'Beta')
      ..correct(claimId: 'claim-1', text: 'I moved', value: '  ');

    expect(hub.correction, isNull);
    expect(controller.loading, isFalse);
    controller.dispose();
    await hub.close();
  });

  test('a hub that refuses the search reports the failure', () async {
    final hub = _UnavailableHub();
    final controller = NativeMemoryController(
      hub: hub,
      events: hub.events,
      requestId: _ids(['search', 'correct', 'delete']),
    );

    controller.search('profile');
    expect(controller.loading, isFalse);
    expect(controller.error, contains('not available'));

    controller.correct(claimId: 'claim-1', text: 'I moved', value: 'Beta');
    expect(controller.error, contains('not available'));

    controller.deleteSource('source-1');
    expect(controller.error, contains('not available'));
    controller.dispose();
    await hub.close();
  });

  test('a deletion refreshes the active query once confirmed', () async {
    final hub = _FakeNativeHub();
    final controller = NativeMemoryController(
      hub: hub,
      events: hub.events,
      requestId: _ids(['search', 'delete', 'refresh']),
      now: () => DateTime.fromMillisecondsSinceEpoch(99),
    );

    controller
      ..search('family')
      ..deleteSource('source-1');
    expect(controller.loading, isTrue);
    hub.add(
      NativeEventMemorySourceDeleted(
        value: MemorySourceDeleted(
          requestId: 'delete',
          sourceId: 'source-1',
          evidenceCount: Uint64.fromBigInt(BigInt.from(3)),
          claimCount: Uint64.fromBigInt(BigInt.two),
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(hub.deletions.single.deletedAtMs, 99);
    expect(hub.searches.last, (requestId: 'refresh', query: 'family'));
    controller.dispose();
    await hub.close();
  });

  test('events for other requests are ignored', () async {
    final hub = _FakeNativeHub();
    final controller = NativeMemoryController(
      hub: hub,
      events: hub.events,
      requestId: _ids(['search']),
    );

    controller.search('profile');
    hub
      ..add(
        const NativeEventError(
          value: NativeError(
            requestId: 'someone-else',
            code: 'memory_search_failed',
            message: 'Not mine',
            retryable: true,
          ),
        ),
      )
      ..add(
        const NativeEventMemorySearchResults(
          value: MemorySearchResults(
            requestId: 'someone-else',
            query: 'other',
            items: [],
            gaps: ['stale'],
          ),
        ),
      );
    await Future<void>.delayed(Duration.zero);

    expect(controller.error, isNull);
    expect(controller.loading, isTrue);
    expect(controller.gaps, isEmpty);
    controller.dispose();
    await hub.close();
  });

  test('a broken event stream is reported rather than swallowed', () async {
    final hub = _FakeNativeHub();
    final controller = NativeMemoryController(
      hub: hub,
      events: hub.events,
      requestId: _ids(['search']),
    );

    controller.search('profile');
    hub.addError(StateError('runtime went away'));
    await Future<void>.delayed(Duration.zero);

    expect(controller.loading, isFalse);
    expect(controller.error, contains('runtime went away'));
    controller.dispose();
    await hub.close();
  });

  test('a disposed controller stops reacting to the runtime', () async {
    final hub = _FakeNativeHub();
    final controller = NativeMemoryController(
      hub: hub,
      events: hub.events,
      requestId: _ids(['search']),
    );

    controller.search('profile');
    controller.dispose();
    hub.add(
      const NativeEventMemorySearchResults(
        value: MemorySearchResults(
          requestId: 'search',
          query: 'profile',
          items: [],
          gaps: ['late'],
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.gaps, isEmpty);
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
  final deletions = <({String requestId, int deletedAtMs})>[];

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  void add(NativeEvent event) => _events.add(event);

  void addError(Object error) => _events.addError(error);

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
  void deleteMemorySource({
    required String requestId,
    required String sourceId,
    required int deletedAtMs,
  }) => deletions.add((requestId: requestId, deletedAtMs: deletedAtMs));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A hub whose runtime never came up, so every command throws synchronously.
final class _UnavailableHub implements NativeHub {
  final _events = StreamController<NativeEvent>.broadcast(sync: true);

  @override
  bool get available => false;

  @override
  Stream<NativeEvent> get events => _events.stream;

  Future<void> close() => _events.close();

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  }) => throw const NativeHubUnavailable('Native hub is not available.');

  @override
  void correctMemory({
    required String requestId,
    required String claimId,
    required String text,
    required String value,
    required int occurredAtMs,
    required int recordedAtMs,
  }) => throw const NativeHubUnavailable('Native hub is not available.');

  @override
  void deleteMemorySource({
    required String requestId,
    required String sourceId,
    required int deletedAtMs,
  }) => throw const NativeHubUnavailable('Native hub is not available.');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
