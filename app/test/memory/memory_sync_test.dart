import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/memory/memory.dart';
import 'package:omi/native/generated/signals/signals.dart';
import 'package:omi/native/native_hub.dart';

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
