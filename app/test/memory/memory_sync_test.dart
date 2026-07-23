import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/memory/memory.dart';
import 'package:omi/native/generated/signals/signals.dart';
import 'package:omi/native/native_hub.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'advances applied cursor only after a complete commit is confirmed',
    () async {
      final hub = _ExportHub([
        const MemoryExported(
          requestId: '',
          exportFormat: 1,
          databaseSchemaVersion: 8,
          highWaterMark: 1,
          nextAfterCommit: 0,
          nextAfterEventIndex: 0,
          complete: false,
          commits: [
            MemoryExportCommit(
              sequence: 1,
              recordedAtMs: 10,
              eventCount: 2,
              firstEventIndex: 0,
              recordsJson: ['{"kind":"claim","record":{}}'],
            ),
          ],
        ),
        const MemoryExported(
          requestId: '',
          exportFormat: 1,
          databaseSchemaVersion: 8,
          highWaterMark: 1,
          nextAfterCommit: 1,
          nextAfterEventIndex: -1,
          complete: true,
          commits: [
            MemoryExportCommit(
              sequence: 1,
              recordedAtMs: 10,
              eventCount: 2,
              firstEventIndex: 1,
              recordsJson: ['{"kind":"evidence","record":{}}'],
            ),
          ],
        ),
      ]);
      final store = _CursorStore();
      final transport = _SyncTransport(['staged', 'applied']);
      final pump = MemorySyncPump(
        hub: hub,
        events: hub.events,
        transport: transport,
        cursorStore: store,
        interval: const Duration(days: 1),
      );

      pump.start('person-1');
      await store.completed.future.timeout(const Duration(seconds: 2));

      expect(store.saved[0].appliedCommit, 0);
      expect(store.saved[0].requestEventIndex, 0);
      expect(store.saved[1].appliedCommit, 1);
      expect(store.saved[1].requestCommit, 1);
      expect(transport.bodies[0]['replica_id'], 'replica-1');
      pump.dispose();
      await hub.close();
    },
  );

  test('a page with no commits is not uploaded at all', () async {
    final hub = _ExportHub([_page(commits: const [])]);
    final store = _CursorStore();
    final transport = _RecordingTransport((_) => const {});
    final pump = MemorySyncPump(
      hub: hub,
      events: hub.events,
      transport: transport,
      cursorStore: store,
      interval: const Duration(days: 1),
    );

    pump.start('person-1');
    await _settle();

    expect(transport.bodies, isEmpty);
    expect(store.saved, isEmpty);
    pump.dispose();
    await hub.close();
  });

  test('a malformed acknowledgement never advances the cursor', () async {
    final acknowledgements = <String, Map<String, Object?>>{
      'a foreign replica': {
        'replica_id': 'someone-else',
        'commits': [
          {'sequence': 1, 'status': 'applied'},
        ],
      },
      'commits that are not a list': {
        'replica_id': 'replica-1',
        'commits': 'applied',
      },
      'a status entry of the wrong shape': {
        'replica_id': 'replica-1',
        'commits': ['applied'],
      },
      'a sequence that is not an integer': {
        'replica_id': 'replica-1',
        'commits': [
          {'sequence': '1', 'status': 'applied'},
        ],
      },
      'a missing commit': {'replica_id': 'replica-1', 'commits': <Object?>[]},
      'an unknown status': {
        'replica_id': 'replica-1',
        'commits': [
          {'sequence': 1, 'status': 'exploded'},
        ],
      },
    };

    for (final entry in acknowledgements.entries) {
      final hub = _ExportHub([_page()]);
      final store = _CursorStore();
      final pump = MemorySyncPump(
        hub: hub,
        events: hub.events,
        transport: _RecordingTransport((_) => entry.value),
        cursorStore: store,
        interval: const Duration(days: 1),
      );

      pump.start('person-1');
      await _settle();

      expect(store.saved, isEmpty, reason: entry.key);
      pump.dispose();
      await hub.close();
    }
  });

  test('a rejected upload leaves the cursor where it was', () async {
    final hub = _ExportHub([_page()]);
    final store = _CursorStore();
    final pump = MemorySyncPump(
      hub: hub,
      events: hub.events,
      transport: _RecordingTransport(
        (_) => throw StateError('Memory sync was rejected (503)'),
      ),
      cursorStore: store,
      interval: const Duration(days: 1),
    );

    pump.start('person-1');
    await _settle();

    expect(store.saved, isEmpty);
    expect(store.cursor.appliedCommit, 0);
    pump.dispose();
    await hub.close();
  });

  test('an export that never arrives never advances the cursor', () async {
    final hub = _SilentHub();
    final store = _CursorStore();
    final pump = MemorySyncPump(
      hub: hub,
      events: hub.events,
      transport: _RecordingTransport((_) => const {}),
      cursorStore: store,
      interval: const Duration(days: 1),
    );

    pump.start('person-1');
    await _settle();

    expect(hub.exports, hasLength(1));
    expect(store.saved, isEmpty);
    pump.dispose();
    await hub.close();
  });

  test('stopping abandons the run before anything is uploaded', () async {
    final hub = _ExportHub([_page()]);
    final store = _CursorStore();
    final transport = _RecordingTransport(
      (_) => const {'replica_id': 'replica-1', 'commits': <Object?>[]},
    );
    final pump = MemorySyncPump(
      hub: hub,
      events: hub.events,
      transport: transport,
      cursorStore: store,
      interval: const Duration(days: 1),
    );

    pump.start('person-1');
    pump.stop();
    await _settle();

    expect(transport.bodies, isEmpty);
    expect(store.saved, isEmpty);
    pump.dispose();
    await hub.close();
  });

  test('starting again for the same person does not double up', () async {
    final hub = _ExportHub([_page(), _page()]);
    final store = _CursorStore();
    final transport = _RecordingTransport(
      (_) => const {
        'replica_id': 'replica-1',
        'commits': [
          {'sequence': 1, 'status': 'applied'},
        ],
      },
    );
    final pump = MemorySyncPump(
      hub: hub,
      events: hub.events,
      transport: transport,
      cursorStore: store,
      interval: const Duration(days: 1),
    );

    pump.start('person-1');
    pump.start('person-1');
    await _settle();

    expect(transport.bodies, hasLength(1));
    expect(store.saved.single.appliedCommit, 1);
    pump.dispose();
    await hub.close();
  });

  test('the export request carries the resume point and high water '
      'mark', () async {
    final hub = _SilentHub();
    final store = _CursorStore()
      ..cursor = (
        requestCommit: 7,
        requestEventIndex: 2,
        appliedCommit: 6,
        highWaterMark: 9,
      );
    final pump = MemorySyncPump(
      hub: hub,
      events: hub.events,
      transport: _RecordingTransport((_) => const {}),
      cursorStore: store,
      interval: const Duration(days: 1),
    );

    pump.start('person-1');
    await _settle();

    expect(hub.exports.single.afterCommit, 7);
    expect(hub.exports.single.afterEventIndex, 2);
    expect(hub.exports.single.highWaterMark, 9);
    pump.dispose();
    await hub.close();
  });

  test('a fresh cursor asks for no high water mark at all', () async {
    final hub = _SilentHub();
    final pump = MemorySyncPump(
      hub: hub,
      events: hub.events,
      transport: _RecordingTransport((_) => const {}),
      cursorStore: _CursorStore(),
      interval: const Duration(days: 1),
    );

    pump.start('person-1');
    await _settle();

    expect(hub.exports.single.highWaterMark, isNull);
    pump.dispose();
    await hub.close();
  });

  group('the persisted cursor', () {
    test('starts at the beginning when nothing is stored', () async {
      SharedPreferences.setMockInitialValues(const {});
      final store = PreferencesMemorySyncCursorStore();

      final cursor = await store.load('person-1');

      expect(cursor.requestCommit, 0);
      expect(cursor.requestEventIndex, -1);
      expect(cursor.appliedCommit, 0);
      expect(cursor.highWaterMark, 0);
    });

    test('round trips per person', () async {
      SharedPreferences.setMockInitialValues(const {});
      final store = PreferencesMemorySyncCursorStore();
      const cursor = (
        requestCommit: 4,
        requestEventIndex: 1,
        appliedCommit: 3,
        highWaterMark: 9,
      );

      await store.save('person-1', cursor);

      expect(await store.load('person-1'), cursor);
      expect((await store.load('person-2')).requestCommit, 0);
    });

    test('a corrupt stored cursor restarts rather than resuming '
        'wrongly', () async {
      for (final stored in const [
        'not json',
        '[]',
        '{"request_commit":"4"}',
        '{"request_commit":4,"request_event_index":1,"applied_commit":3}',
      ]) {
        SharedPreferences.setMockInitialValues({
          'memory-sync-cursor-v1-person-1': stored,
        });

        final cursor = await PreferencesMemorySyncCursorStore().load(
          'person-1',
        );

        expect(cursor.requestCommit, 0, reason: stored);
        expect(cursor.requestEventIndex, -1, reason: stored);
      }
    });

    test('the replica identity is created once and then kept', () async {
      SharedPreferences.setMockInitialValues(const {});
      final store = PreferencesMemorySyncCursorStore();

      final first = await store.replicaId();

      expect(first, isNotEmpty);
      expect(await store.replicaId(), first);
      expect(await PreferencesMemorySyncCursorStore().replicaId(), first);
    });

    test('an empty stored replica identity is replaced', () async {
      SharedPreferences.setMockInitialValues(const {
        'memory-sync-replica-v1': '',
      });

      expect(await PreferencesMemorySyncCursorStore().replicaId(), isNotEmpty);
    });
  });

  group('the worker transport', () {
    WorkerHttpClient worker(http.Client client) => WorkerHttpClient(
      baseUri: Uri.parse('https://api.example.test'),
      sessionProvider: () async => AuthSession(
        uid: 'user-1',
        idToken: 'firebase-token',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      ),
      client: client,
    );

    test('posts the export to the sync endpoint', () async {
      late http.Request sent;
      final transport = WorkerMemorySyncTransport(
        worker(
          MockClient((request) async {
            sent = request;
            return http.Response('{"replica_id":"replica-1"}', 200);
          }),
        ),
      );

      final acknowledgement = await transport.upload({'replica_id': 'r'});

      expect(sent.url.path, '/v1/memory/zkr-sync');
      expect(sent.method, 'POST');
      expect(acknowledgement, {'replica_id': 'replica-1'});
    });

    test('a rejected sync names the status code', () async {
      final transport = WorkerMemorySyncTransport(
        worker(MockClient((_) async => http.Response('{"error":"no"}', 503))),
      );

      await expectLater(
        transport.upload(const {}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Memory sync was rejected (503)',
          ),
        ),
      );
    });

    test('a non-object acknowledgement is rejected', () async {
      final transport = WorkerMemorySyncTransport(
        worker(MockClient((_) async => http.Response('[]', 200))),
      );

      await expectLater(
        transport.upload(const {}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Memory sync returned an invalid response',
          ),
        ),
      );
    });
  });
}

Future<void> _settle() async {
  for (var index = 0; index < 8; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

MemoryExported _page({
  List<MemoryExportCommit> commits = const [
    MemoryExportCommit(
      sequence: 1,
      recordedAtMs: 10,
      eventCount: 1,
      firstEventIndex: 0,
      recordsJson: ['{"kind":"claim","record":{}}'],
    ),
  ],
}) => MemoryExported(
  requestId: '',
  exportFormat: 1,
  databaseSchemaVersion: 8,
  highWaterMark: 1,
  nextAfterCommit: 1,
  nextAfterEventIndex: -1,
  complete: true,
  commits: commits,
);

final class _RecordingTransport implements MemorySyncTransport {
  _RecordingTransport(this._reply);

  final Map<String, Object?> Function(Map<String, Object?>) _reply;
  final bodies = <Map<String, Object?>>[];

  @override
  Future<Map<String, Object?>> upload(Map<String, Object?> body) async {
    bodies.add(body);
    return _reply(body);
  }
}

/// A hub that takes the export request and never answers it, which is what a
/// wedged native runtime looks like from here.
final class _SilentHub implements NativeHub {
  final _events = StreamController<NativeEvent>.broadcast(sync: true);
  final exports =
      <({int afterCommit, int afterEventIndex, int? highWaterMark})>[];

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  Future<void> close() => _events.close();

  @override
  void exportMemory({
    required String requestId,
    int afterCommit = 0,
    int afterEventIndex = -1,
    int? highWaterMark,
    int limit = 100,
  }) => exports.add((
    afterCommit: afterCommit,
    afterEventIndex: afterEventIndex,
    highWaterMark: highWaterMark,
  ));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CursorStore implements MemorySyncCursorStore {
  final saved = <MemorySyncCursor>[];
  final completed = Completer<void>();
  MemorySyncCursor cursor = (
    requestCommit: 0,
    requestEventIndex: -1,
    appliedCommit: 0,
    highWaterMark: 0,
  );

  @override
  Future<MemorySyncCursor> load(String uid) async => cursor;

  @override
  Future<String> replicaId() async => 'replica-1';

  @override
  Future<void> save(String uid, MemorySyncCursor value) async {
    cursor = value;
    saved.add(value);
    if (saved.length == 2 && !completed.isCompleted) completed.complete();
  }
}

final class _SyncTransport implements MemorySyncTransport {
  _SyncTransport(this.statuses);

  final List<String> statuses;
  final bodies = <Map<String, Object?>>[];

  @override
  Future<Map<String, Object?>> upload(Map<String, Object?> body) async {
    bodies.add(body);
    final commits = body['commits']! as List<Object?>;
    final commit = commits.single! as Map<String, Object?>;
    return {
      'replica_id': 'replica-1',
      'commits': [
        {'sequence': commit['sequence'], 'status': statuses.removeAt(0)},
      ],
    };
  }
}

final class _ExportHub implements NativeHub {
  _ExportHub(this.pages);

  final List<MemoryExported> pages;
  final _events = StreamController<NativeEvent>.broadcast(sync: true);

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  Future<void> close() => _events.close();

  @override
  void exportMemory({
    required String requestId,
    int afterCommit = 0,
    int afterEventIndex = -1,
    int? highWaterMark,
    int limit = 100,
  }) {
    final page = pages.removeAt(0);
    scheduleMicrotask(
      () => _events.add(
        NativeEventMemoryExported(value: page.copyWith(requestId: requestId)),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
