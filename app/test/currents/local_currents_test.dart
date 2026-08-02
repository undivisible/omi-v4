import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  test('an offline load builds currents from the local memory store', () async {
    final hub = _Hub([
      _memory('m-1', 'Fix the sync retry', 'It drops the cursor on 429.', 200),
      _memory('m-2', 'Call the landlord', 'About the lease renewal.', 400),
    ]);
    final controller = CurrentsController(
      CurrentsClient(_FailingTransport()),
      hub: hub,
      local: LocalCurrentsSource(hub, now: () => DateTime.utc(2026, 7, 23)),
      now: () => DateTime.utc(2026, 7, 23),
    );

    await controller.load(offline: true);

    expect(controller.error, isNull);
    expect(controller.localOnly, isTrue);
    expect(controller.items.map((card) => card.title), [
      'Call the landlord',
      'Fix the sync retry',
    ]);
    expect(controller.items.first.summary, 'About the lease renewal.');
    expect(controller.items.first.item.evidence.single.sourceId, 'm-2');
  });

  test(
    'a daily review reads as a headline, a date, and its provenance',
    () async {
      final hub = _Hub([
        MemoryItem(
          kind: 'daily_review',
          id: 'c45342b4b8b95b36a14928b65f8b54e9',
          title: '2026-07-24',
          body: 'You worked on the portfolio website.',
          recordedAtMs: DateTime.utc(2026, 7, 24, 21).millisecondsSinceEpoch,
          evidenceIds: const ['capture-1'],
        ),
      ]);
      final controller = CurrentsController(
        CurrentsClient(_FailingTransport()),
        hub: hub,
        local: LocalCurrentsSource(hub, now: () => DateTime.utc(2026, 7, 25)),
        now: () => DateTime.utc(2026, 7, 25),
      );

      await controller.load(offline: true);

      final card = controller.items.single;
      expect(card.title, 'You worked on the portfolio website.');
      expect(card.metadata!['detail'], '24 July');
      expect(card.sourceKind, 'daily review');
      final evidence = card.item.evidence.single;
      expect(evidence.reason, 'From your daily review, 24 July');
      expect(evidence.reason, isNot(contains(evidence.sourceId)));
      expect(card.item.proposedNextStep, isEmpty);
    },
  );

  test('a memory with no genuine next step proposes none', () async {
    final hub = _Hub([
      _memory('m-1', 'Fix the sync retry', 'It drops the cursor on 429.', 200),
    ]);
    final controller = CurrentsController(
      CurrentsClient(_FailingTransport()),
      hub: hub,
      local: LocalCurrentsSource(hub, now: () => DateTime.utc(2026, 7, 23)),
      now: () => DateTime.utc(2026, 7, 23),
    );

    await controller.load(offline: true);

    expect(controller.items.single.item.proposedNextStep, isEmpty);
  });

  test('an offline brief is composed from the local currents', () async {
    final hub = _Hub([
      _memory('m-1', 'Fix the sync retry', 'It drops the cursor on 429.', 200),
    ]);
    final controller = CurrentsController(
      CurrentsClient(_FailingTransport()),
      hub: hub,
      local: LocalCurrentsSource(hub, now: () => DateTime.utc(2026, 7, 23)),
      now: () => DateTime.utc(2026, 7, 23, 9, 5),
    );

    await controller.load(offline: true);

    expect(hub.composed.single.items.single.title, 'Fix the sync retry');
    hub.answer(hub.composed.single.requestId, 'text "Fix the sync retry"');
    await Future<void>.delayed(Duration.zero);
    expect(controller.briefCrepus, 'text "Fix the sync retry"');
  });

  test('an empty local store reports no currents and no error', () async {
    final hub = _Hub(const []);
    final controller = CurrentsController(
      CurrentsClient(_FailingTransport()),
      hub: hub,
      local: LocalCurrentsSource(hub, now: () => DateTime.utc(2026, 7, 23)),
    );

    await controller.load(offline: true);

    expect(controller.items, isEmpty);
    expect(controller.error, isNull);
    expect(controller.localOnly, isTrue);
  });

  test('signing in replaces the local currents rather than stacking on '
      'them', () async {
    final hub = _Hub([
      _memory('m-1', 'Fix the sync retry', 'It drops the cursor on 429.', 200),
    ]);
    final controller = CurrentsController(
      CurrentsClient(_Transport()),
      hub: hub,
      local: LocalCurrentsSource(hub, now: () => DateTime.utc(2026, 7, 23)),
      now: () => DateTime.utc(2026, 7, 23),
    );

    await controller.load(offline: true);
    expect(controller.items.single.title, 'Fix the sync retry');

    await controller.load();

    expect(controller.localOnly, isFalse);
    expect(controller.items.single.title, 'Ship release');
  });

  test('a hub that never answers leaves an empty offline list', () async {
    final controller = CurrentsController(
      CurrentsClient(_FailingTransport()),
      local: LocalCurrentsSource(
        const UnavailableNativeHub('no native hub here'),
      ),
    );

    await controller.load(offline: true);

    expect(controller.items, isEmpty);
    expect(controller.error, isNull);
  });
}

MemoryItem _memory(String id, String title, String body, int recordedAtMs) =>
    MemoryItem(
      kind: 'note',
      id: id,
      title: title,
      body: body,
      recordedAtMs: recordedAtMs,
      evidenceIds: const [],
    );

final class _Composed {
  const _Composed(this.requestId, this.items);

  final String requestId;
  final List<BriefItem> items;
}

final class _Hub implements NativeHub {
  _Hub(this._items);

  final List<MemoryItem> _items;
  final _events = StreamController<NativeEvent>.broadcast();
  final composed = <_Composed>[];

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  @override
  void listMemoryItems({required String requestId, int limit = 50}) =>
      scheduleMicrotask(
        () => _events.add(
          NativeEventMemoryItems(
            value: MemoryItems(
              requestId: requestId,
              items: _items.take(limit).toList(),
            ),
          ),
        ),
      );

  @override
  void composeBrief({
    required String requestId,
    required String nowLocal,
    required List<BriefItem> items,
  }) => composed.add(_Composed(requestId, items));

  void answer(String requestId, String? crepus) => _events.add(
    NativeEventBriefComposed(
      value: BriefComposed(requestId: requestId, crepus: crepus),
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FailingTransport implements CurrentsTransport {
  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async =>
      const CurrentsResponse(statusCode: 401);
}

final class _Transport implements CurrentsTransport {
  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async {
    if (request.path.endsWith('/generate')) {
      return const CurrentsResponse(statusCode: 200, body: {'current': null});
    }
    return CurrentsResponse(
      statusCode: 200,
      body: {
        'currents': [_current],
      },
    );
  }
}

const _current = <String, Object?>{
  'id': 'current-1',
  'title': 'Ship release',
  'summary': 'The release checklist is unfinished.',
  'status': 'surfaced',
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
  'feedbackReference': null,
  'executionReference': null,
  'createdAt': '2026-07-21T12:00:00.000Z',
  'updatedAt': '2026-07-21T12:00:00.000Z',
};
