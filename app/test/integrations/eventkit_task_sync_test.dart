import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/integrations/apple_eventkit.dart';
import 'package:omi/integrations/eventkit_task_sync.dart';

void main() {
  CurrentCard card(
    String id, {
    DateTime? expiresAt,
    String status = 'surfaced',
  }) => CurrentCard.fromJson({
    'id': id,
    'status': status,
    'evidence': [
      {'sourceId': 'src-$id', 'reason': 'observed'},
    ],
    'reason': 'reason for $id',
    'timing': {
      'surfaceAt': '2026-07-22T08:00:00Z',
      if (expiresAt != null) 'expiresAt': expiresAt.toIso8601String(),
    },
    'confidence': 0.8,
    'proposedNextStep': 'Next step for $id',
    'createdAt': '2026-07-22T07:00:00Z',
    'updatedAt': '2026-07-22T07:00:00Z',
    'title': 'Task $id',
    'summary': 'Summary for $id',
  });

  final shortDue = DateTime.utc(2026, 7, 22, 10);
  final longDue = DateTime.utc(2026, 7, 30, 10);

  test('toggle off means no writes', () async {
    final writer = _FakeWriter();
    final sync = EventKitTaskSync(
      writer: writer,
      store: VolatileEventKitTaskSyncStore(),
    );

    await sync.apply([card('a', expiresAt: shortDue)]);

    expect(writer.upserts, isEmpty);
    expect(writer.completions, isEmpty);
    expect(writer.removals, isEmpty);
  });

  test(
    'creates one event for a time-bound current and stays idempotent',
    () async {
      final writer = _FakeWriter();
      final store = VolatileEventKitTaskSyncStore(isEnabled: true);
      final sync = EventKitTaskSync(writer: writer, store: store);

      await sync.apply([card('a', expiresAt: shortDue)]);
      await sync.apply([card('a', expiresAt: shortDue)]);

      expect(writer.items, hasLength(1));
      final entry = writer.items.values.single;
      expect(entry.source, AppleEventKitSource.calendar);
      expect(entry.title, 'Task a');
      expect(entry.notes, contains('omi-current:a'));
      expect(entry.startAt, DateTime.utc(2026, 7, 22, 8));
      expect(entry.endAt, shortDue);
      expect(writer.upserts, hasLength(2));
      expect(writer.upserts[1].nativeId, writer.upserts[0].returnedId);
      expect(store.items['a']?.source, AppleEventKitSource.calendar);
    },
  );

  test('long-window currents become reminders due at expiry', () async {
    final writer = _FakeWriter();
    final sync = EventKitTaskSync(
      writer: writer,
      store: VolatileEventKitTaskSyncStore(isEnabled: true),
    );

    await sync.apply([card('b', expiresAt: longDue)]);

    final entry = writer.items.values.single;
    expect(entry.source, AppleEventKitSource.reminders);
    expect(entry.dueAt, longDue);
  });

  test('currents without a due component are not written', () async {
    final writer = _FakeWriter();
    final sync = EventKitTaskSync(
      writer: writer,
      store: VolatileEventKitTaskSyncStore(isEnabled: true),
    );

    await sync.apply([card('c')]);

    expect(writer.upserts, isEmpty);
  });

  test(
    'a disappeared reminder is marked completed and an event removed',
    () async {
      final writer = _FakeWriter();
      final store = VolatileEventKitTaskSyncStore(isEnabled: true);
      final sync = EventKitTaskSync(writer: writer, store: store);

      await sync.apply([
        card('event', expiresAt: shortDue),
        card('reminder', expiresAt: longDue),
      ]);
      await sync.apply(const []);

      expect(writer.completions, hasLength(1));
      expect(writer.removals, hasLength(1));
      expect(store.items, isEmpty);
    },
  );

  test('denied access writes nothing', () async {
    final writer = _FakeWriter(
      authorization: AppleEventKitAuthorization.denied,
    );
    final sync = EventKitTaskSync(
      writer: writer,
      store: VolatileEventKitTaskSyncStore(isEnabled: true),
    );

    await sync.apply([card('a', expiresAt: shortDue)]);

    expect(writer.upserts, isEmpty);
  });
}

final class _FakeItem {
  _FakeItem({
    required this.source,
    required this.title,
    required this.notes,
    this.startAt,
    this.endAt,
    this.dueAt,
  });

  final AppleEventKitSource source;
  final String title;
  final String notes;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? dueAt;
}

final class _FakeUpsert {
  _FakeUpsert({required this.nativeId, required this.returnedId});

  final String? nativeId;
  final String returnedId;
}

final class _FakeWriter implements AppleEventKitWriter {
  _FakeWriter({this.authorization = AppleEventKitAuthorization.fullAccess});

  final AppleEventKitAuthorization authorization;
  final items = <String, _FakeItem>{};
  final upserts = <_FakeUpsert>[];
  final completions = <String>[];
  final removals = <String>[];
  int _nextId = 0;

  @override
  bool get available => true;

  @override
  Future<AppleEventKitAuthorization> status(AppleEventKitSource source) async =>
      authorization;

  @override
  Future<AppleEventKitAuthorization> request(
    AppleEventKitSource source,
  ) async => authorization;

  @override
  Future<String?> upsertItem({
    required AppleEventKitSource source,
    required String currentId,
    required String title,
    required String notes,
    String? nativeId,
    DateTime? startAt,
    DateTime? endAt,
    DateTime? dueAt,
  }) async {
    final id = nativeId ?? 'native-${_nextId++}';
    items[id] = _FakeItem(
      source: source,
      title: title,
      notes: notes,
      startAt: startAt,
      endAt: endAt,
      dueAt: dueAt,
    );
    upserts.add(_FakeUpsert(nativeId: nativeId, returnedId: id));
    return id;
  }

  @override
  Future<void> completeItem(AppleEventKitSource source, String nativeId) async {
    completions.add(nativeId);
    items.remove(nativeId);
  }

  @override
  Future<void> removeItem(AppleEventKitSource source, String nativeId) async {
    removals.add(nativeId);
    items.remove(nativeId);
  }
}
