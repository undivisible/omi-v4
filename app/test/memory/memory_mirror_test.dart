import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/memory/memory.dart';
import 'package:omi/native/generated/signals/signals.dart';
import 'package:omi/native/native_hub.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _record(int sequence, String replica, String value) => {
  'sequence': sequence,
  'origin_replica': replica,
  'record_kind': 'claim',
  'record_id': 'claim-1',
  'payload': {'value': value},
  'recorded_at': 11,
};

final class _FakeTransport implements MemoryMirrorTransport {
  _FakeTransport(this.pages);

  final List<Map<String, Object?>> pages;
  final List<int> requestedAfter = [];
  int _index = 0;

  @override
  Future<Map<String, Object?>> fetchLog({
    required int after,
    required int limit,
    required String replicaId,
  }) async {
    requestedAfter.add(after);
    if (_index >= pages.length) {
      return {
        'records': [],
        'next_after': after,
        'head': after,
        'complete': true,
      };
    }
    return pages[_index++];
  }
}

final class _FailingStore implements MemoryMirrorStore {
  @override
  Future<int> mirroredSequence(String uid) async => 0;

  @override
  Future<void> apply(String uid, List<MemoryMirrorRecord> records) async =>
      throw StateError('store is offline');
}

final class _ApplyHub implements NativeHub {
  _ApplyHub(this._events, {this.failFirst = false});

  final StreamController<NativeEvent> _events;
  final bool failFirst;
  final applyCalls = <List<MemoryApplyCommit>>[];

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  @override
  void applyMemory({
    required String requestId,
    required List<MemoryApplyCommit> commits,
    bool applyDeletions = false,
  }) {
    applyCalls.add(commits);
    if (failFirst && applyCalls.length == 1) {
      _events.add(
        NativeEventError(
          value: NativeError(
            requestId: requestId,
            code: 'memory_apply_failed',
            message: 'apply rejected',
            retryable: true,
          ),
        ),
      );
      return;
    }
    _events.add(
      NativeEventMemoryApplied(
        value: MemoryApplied(
          requestId: requestId,
          commitsApplied: _count(commits.length),
          commitsSkipped: _count(0),
          recordsApplied: _count(commits.length),
          recordsSkipped: _count(0),
        ),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _IdempotentApplyHub implements NativeHub {
  _IdempotentApplyHub(this._events);

  final StreamController<NativeEvent> _events;
  final applyCalls = <List<MemoryApplyCommit>>[];

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  @override
  void applyMemory({
    required String requestId,
    required List<MemoryApplyCommit> commits,
    bool applyDeletions = false,
  }) {
    applyCalls.add(commits);
    final skipped = applyCalls.length == 1 ? 0 : commits.length;
    _events.add(
      NativeEventMemoryApplied(
        value: MemoryApplied(
          requestId: requestId,
          commitsApplied: _count(commits.length - skipped),
          commitsSkipped: _count(skipped),
          recordsApplied: _count(commits.length - skipped),
          recordsSkipped: _count(skipped),
        ),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FailingApplyHub implements NativeHub {
  _FailingApplyHub(this._events);

  final StreamController<NativeEvent> _events;

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  @override
  void applyMemory({
    required String requestId,
    required List<MemoryApplyCommit> commits,
    bool applyDeletions = false,
  }) {
    _events.add(
      NativeEventError(
        value: NativeError(
          requestId: requestId,
          code: 'memory_apply_failed',
          message: 'apply rejected',
          retryable: false,
        ),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _BlockingTransport implements MemoryMirrorTransport {
  _BlockingTransport(this.page);

  final Map<String, Object?> page;
  final blocked = Completer<void>();

  @override
  Future<Map<String, Object?>> fetchLog({
    required int after,
    required int limit,
    required String replicaId,
  }) async {
    await blocked.future;
    return page;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('drains every page and advances the cursor to the head', () async {
    final transport = _FakeTransport([
      {
        'records': [_record(1, 'desktop', 'Acme')],
        'next_after': 1,
        'head': 2,
        'complete': false,
      },
      {
        'records': [_record(2, 'mobile', 'Beta')],
        'next_after': 2,
        'head': 2,
        'complete': true,
      },
    ]);
    final store = InMemoryMemoryMirrorStore();
    final cursor = PreferencesMemoryMirrorCursor();
    final pump = MemoryMirrorPump(
      transport: transport,
      store: store,
      cursor: cursor,
      replicaId: 'desktop',
    );

    expect(await pump.pull('alpha'), 2);
    expect(transport.requestedAfter, [0, 1]);
    expect(await cursor.load('alpha'), 2);
    final mirrored = store.records('alpha');
    expect(mirrored.length, 2);
    expect(mirrored.map((record) => record.originReplica), [
      'desktop',
      'mobile',
    ]);
  });

  test(
    'authoritative log tracer preserves order, canonical replays, revisions, retries, and origins',
    () async {
      final record =
          (int sequence, String originReplica, Map<String, Object?> payload) =>
              (
                sequence: sequence,
                originReplica: originReplica,
                recordKind: 'claim',
                recordId: 'claim-1',
                payload: payload,
                recordedAt: 11,
              );
      final local = record(1, 'desktop', {'value': 'local'});
      final cloud = record(2, 'cloud', {'a': 'Acme', 'b': 1});
      final cloudReplay = record(3, 'cloud', {'b': 1, 'a': 'Acme'});
      final cloudRevision = record(4, 'cloud', {'value': 'revised'});
      final foreign = record(5, 'mobile', {'value': 'foreign'});
      final logPage = <String, Object?>{
        'records': [local, cloud, cloudReplay, cloudRevision, foreign]
            .map(
              (entry) => <String, Object?>{
                'sequence': entry.sequence,
                'origin_replica': entry.originReplica,
                'record_kind': entry.recordKind,
                'record_id': entry.recordId,
                'payload': entry.payload,
                'recorded_at': entry.recordedAt,
              },
            )
            .toList(),
        'next_after': 5,
        'head': 5,
        'complete': true,
      };

      final mirror = InMemoryMemoryMirrorStore();
      await mirror.apply('alpha', [local, cloud, cloudReplay]);
      expect(mirror.records('alpha').map((entry) => entry.sequence), [1, 2]);
      await mirror.apply('alpha', [cloudRevision, foreign]);
      expect(mirror.records('alpha').map((entry) => entry.sequence), [1, 4, 5]);
      expect(mirror.records('alpha')[1].payload['value'], 'revised');

      final events = StreamController<NativeEvent>.broadcast();
      final hub = _ApplyHub(events, failFirst: true);
      final cursor = PreferencesMemoryMirrorCursor();
      final transport = _FakeTransport([logPage, logPage]);
      final pump = MemoryMirrorPump(
        transport: transport,
        store: HubMemoryMirrorStore(
          hub: hub,
          events: events.stream,
          replicaId: 'desktop',
        ),
        cursor: cursor,
        replicaId: 'desktop',
      );

      expect(await pump.pull('alpha'), 0);
      expect(await cursor.load('alpha'), 0);
      expect(await pump.pull('alpha'), 5);
      expect(transport.requestedAfter, [0, 0]);
      expect(await cursor.load('alpha'), 5);
      expect(hub.applyCalls, hasLength(2));
      expect(hub.applyCalls.last.map((commit) => commit.sequence.toInt()), [
        2,
        3,
        4,
        5,
      ]);
      await events.close();
    },
  );

  test(
    'a later sequence supersedes an earlier one for the same identity',
    () async {
      final store = InMemoryMemoryMirrorStore();
      final pump = MemoryMirrorPump(
        transport: _FakeTransport([
          {
            'records': [
              _record(1, 'desktop', 'Acme'),
              _record(3, 'desktop', 'Gamma'),
            ],
            'next_after': 3,
            'head': 3,
            'complete': true,
          },
        ]),
        store: store,
        cursor: PreferencesMemoryMirrorCursor(),
        replicaId: 'desktop',
      );

      await pump.pull('alpha');
      final mirrored = store.records('alpha');
      expect(mirrored.length, 1);
      expect(mirrored.single.sequence, 3);
      expect(mirrored.single.payload['value'], 'Gamma');
    },
  );

  test('records from different replicas are never merged', () async {
    final store = InMemoryMemoryMirrorStore();
    final pump = MemoryMirrorPump(
      transport: _FakeTransport([
        {
          'records': [
            _record(1, 'desktop', 'Acme'),
            _record(2, 'mobile', 'Acme'),
          ],
          'next_after': 2,
          'head': 2,
          'complete': true,
        },
      ]),
      store: store,
      cursor: PreferencesMemoryMirrorCursor(),
      replicaId: 'desktop',
    );

    await pump.pull('alpha');
    expect(store.records('alpha').length, 2);
  });

  test('the cursor does not advance when the store rejects a page', () async {
    final cursor = PreferencesMemoryMirrorCursor();
    final pump = MemoryMirrorPump(
      transport: _FakeTransport([
        {
          'records': [_record(1, 'desktop', 'Acme')],
          'next_after': 1,
          'head': 1,
          'complete': true,
        },
      ]),
      store: _FailingStore(),
      cursor: cursor,
      replicaId: 'desktop',
    );

    expect(await pump.pull('alpha'), 0);
    expect(await cursor.load('alpha'), 0);
  });

  test('a cursor ahead of the store rewinds so no record is skipped', () async {
    final cursor = PreferencesMemoryMirrorCursor();
    await cursor.save('alpha', 9);
    final transport = _FakeTransport([
      {
        'records': [_record(1, 'desktop', 'Acme')],
        'next_after': 1,
        'head': 1,
        'complete': true,
      },
    ]);
    final pump = MemoryMirrorPump(
      transport: transport,
      store: InMemoryMemoryMirrorStore(),
      cursor: cursor,
      replicaId: 'desktop',
    );

    await pump.pull('alpha');
    expect(transport.requestedAfter.first, 0);
  });

  test('an out-of-order or malformed page is rejected', () {
    expect(
      () => parseMemoryMirrorPage({
        'records': [
          _record(2, 'desktop', 'Acme'),
          _record(1, 'desktop', 'Beta'),
        ],
        'next_after': 2,
        'head': 2,
        'complete': true,
      }, 0),
      throwsA(isA<MemoryMirrorException>()),
    );
    expect(
      () => parseMemoryMirrorPage({
        'records': [
          {'sequence': 1, 'origin_replica': '', 'record_kind': 'claim'},
        ],
        'next_after': 1,
        'head': 1,
        'complete': true,
      }, 0),
      throwsA(isA<MemoryMirrorException>()),
    );
    expect(
      () => parseMemoryMirrorPage({
        'records': [_record(1, 'desktop', 'Acme')],
        'next_after': 1,
        'head': 1,
      }, 0),
      throwsA(isA<MemoryMirrorException>()),
    );
  });

  test('hub mirror store skips records from the local replica', () async {
    final events = StreamController<NativeEvent>.broadcast();
    final hub = _ApplyHub(events);
    final store = HubMemoryMirrorStore(
      hub: hub,
      events: events.stream,
      replicaId: 'desktop',
    );

    await store.apply('alpha', [
      _mirrorRecord(1, 'desktop', 'local'),
      _mirrorRecord(2, 'cloud', 'remote'),
    ]);

    expect(hub.applyCalls, hasLength(1));
    expect(hub.applyCalls.single.single.sequence, 2);
    expect(await store.mirroredSequence('alpha'), 2);
    await events.close();
  });

  test('hub mirror store accepts idempotent re-apply', () async {
    final events = StreamController<NativeEvent>.broadcast();
    final hub = _IdempotentApplyHub(events);
    final store = HubMemoryMirrorStore(
      hub: hub,
      events: events.stream,
      replicaId: 'desktop',
    );
    final records = [_mirrorRecord(1, 'cloud', 'remote')];

    await store.apply('alpha', records);
    await store.apply('alpha', records);

    expect(hub.applyCalls, hasLength(2));
    expect(await store.mirroredSequence('alpha'), 1);
    await events.close();
  });

  test('hub mirror store surfaces apply failures from the hub', () async {
    final events = StreamController<NativeEvent>.broadcast();
    final hub = _FailingApplyHub(events);
    final store = HubMemoryMirrorStore(
      hub: hub,
      events: events.stream,
      replicaId: 'desktop',
    );

    await expectLater(
      store.apply('alpha', [_mirrorRecord(1, 'cloud', 'remote')]),
      throwsA(
        isA<MemoryMirrorException>().having(
          (error) => error.message,
          'message',
          'apply rejected',
        ),
      ),
    );
    await events.close();
  });

  test('a concurrent pull returns without overlapping work', () async {
    final transport = _BlockingTransport({
      'records': [_record(1, 'desktop', 'Acme')],
      'next_after': 1,
      'head': 1,
      'complete': true,
    });
    final pump = MemoryMirrorPump(
      transport: transport,
      store: InMemoryMemoryMirrorStore(),
      cursor: PreferencesMemoryMirrorCursor(),
      replicaId: 'desktop',
    );

    final first = pump.pull('alpha');
    final second = pump.pull('alpha');
    transport.blocked.complete();
    expect(await second, 0);
    expect(await first, 1);
  });

  test('mirror failures invoke onFailure without crashing the pump', () async {
    Object? reported;
    final pump = MemoryMirrorPump(
      transport: _FakeTransport([
        {
          'records': [_record(1, 'desktop', 'Acme')],
          'next_after': 1,
          'head': 1,
          'complete': true,
        },
      ]),
      store: _FailingStore(),
      cursor: PreferencesMemoryMirrorCursor(),
      replicaId: 'desktop',
      onFailure: (error, _) => reported = error,
    );

    expect(await pump.pull('alpha'), 0);
    expect(reported, isA<StateError>());
  });

  test('stop invalidates generation-bound pulls', () async {
    final pump = MemoryMirrorPump(
      transport: _FakeTransport([
        {
          'records': [_record(1, 'desktop', 'Acme')],
          'next_after': 1,
          'head': 1,
          'complete': true,
        },
      ]),
      store: InMemoryMemoryMirrorStore(),
      cursor: PreferencesMemoryMirrorCursor(),
      replicaId: 'desktop',
    );

    pump.start('alpha');
    pump.stop();
    expect(await pump.pull('alpha', 2), 0);
  });
}

MemoryMirrorRecord _mirrorRecord(int sequence, String replica, String value) =>
    (
      sequence: sequence,
      originReplica: replica,
      recordKind: 'claim',
      recordId: 'claim-1',
      payload: {'value': value},
      recordedAt: 11,
    );

Uint64 _count(int value) => Uint64.fromBigInt(BigInt.from(value));
