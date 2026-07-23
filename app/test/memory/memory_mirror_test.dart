import 'package:flutter_test/flutter_test.dart';
import 'package:omi/memory/memory.dart';
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

    await expectLater(pump.pull('alpha'), throwsStateError);
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
}
