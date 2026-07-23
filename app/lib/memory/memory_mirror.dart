import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/worker_http.dart';

/// The device-side mirror of the authoritative cloud memory log.
///
/// The cloud assigns every record its sequence; this pulls that stream down so
/// a device can recall memory while disconnected, including memory captured on
/// other replicas. Nothing here decides ordering or resolves conflicts — the
/// log arrives already ordered, and a record is only ever appended, so the
/// mirror is a pure downstream consumer. See `docs/memory-authority.md`.
///
/// This path deliberately does not touch the Rust hub, so it works on web.
typedef MemoryMirrorRecord = ({
  int sequence,
  String originReplica,
  String recordKind,
  String recordId,
  Map<String, Object?> payload,
  int recordedAt,
});

typedef MemoryMirrorPage = ({
  List<MemoryMirrorRecord> records,
  int nextAfter,
  int head,
  bool complete,
});

final class MemoryMirrorException implements Exception {
  const MemoryMirrorException(this.message);

  final String message;

  @override
  String toString() => 'MemoryMirrorException: $message';
}

abstract interface class MemoryMirrorTransport {
  Future<Map<String, Object?>> fetchLog({
    required int after,
    required int limit,
    required String replicaId,
  });
}

final class WorkerMemoryMirrorTransport implements MemoryMirrorTransport {
  const WorkerMemoryMirrorTransport(this._worker);

  final WorkerHttpClient _worker;

  @override
  Future<Map<String, Object?>> fetchLog({
    required int after,
    required int limit,
    required String replicaId,
  }) async {
    final response = await _worker.send(
      method: 'GET',
      path: '/v1/memory/log',
      query: {'after': '$after', 'limit': '$limit', 'replica_id': replicaId},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MemoryMirrorException(
        'Memory log request failed (${response.statusCode})',
      );
    }
    if (response.body is! Map<String, Object?>) {
      throw const MemoryMirrorException('Memory log returned an invalid page');
    }
    return response.body! as Map<String, Object?>;
  }
}

/// Where the mirrored records land. Kept behind an interface so the durable
/// store can differ per platform without the pull logic knowing.
abstract interface class MemoryMirrorStore {
  Future<int> mirroredSequence(String uid);
  Future<void> apply(String uid, List<MemoryMirrorRecord> records);
}

final class InMemoryMemoryMirrorStore implements MemoryMirrorStore {
  final Map<String, int> _sequences = {};
  final Map<String, Map<String, MemoryMirrorRecord>> _records = {};

  /// The current revision of every mirrored record, newest sequence wins.
  List<MemoryMirrorRecord> records(String uid) =>
      (_records[uid]?.values.toList() ?? <MemoryMirrorRecord>[])
        ..sort((a, b) => a.sequence.compareTo(b.sequence));

  @override
  Future<int> mirroredSequence(String uid) async => _sequences[uid] ?? 0;

  @override
  Future<void> apply(String uid, List<MemoryMirrorRecord> records) async {
    final byIdentity = _records.putIfAbsent(uid, () => {});
    for (final record in records) {
      final identity = jsonEncode([
        record.originReplica,
        record.recordKind,
        record.recordId,
      ]);
      final existing = byIdentity[identity];
      if (existing == null || record.sequence > existing.sequence) {
        byIdentity[identity] = record;
      }
      _sequences[uid] = record.sequence > (_sequences[uid] ?? 0)
          ? record.sequence
          : _sequences[uid]!;
    }
  }
}

/// Persists only the cursor. Records themselves belong in the platform store;
/// keeping the cursor separate means a mirror that loses its records refetches
/// from zero rather than silently claiming to be caught up.
final class PreferencesMemoryMirrorCursor {
  static String _key(String uid) => 'memory-mirror-cursor-v1-$uid';

  Future<int> load(String uid) async =>
      (await SharedPreferences.getInstance()).getInt(_key(uid)) ?? 0;

  Future<void> save(String uid, int sequence) async {
    final saved = await (await SharedPreferences.getInstance()).setInt(
      _key(uid),
      sequence,
    );
    if (!saved) throw StateError('Could not persist memory mirror cursor');
  }
}

int _integer(Object? value, String field) {
  if (value is! int || value < 0) {
    throw MemoryMirrorException('Memory log $field was invalid');
  }
  return value;
}

MemoryMirrorRecord _record(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const MemoryMirrorException('Memory log record was not an object');
  }
  final originReplica = value['origin_replica'];
  final recordKind = value['record_kind'];
  final recordId = value['record_id'];
  final payload = value['payload'];
  if (originReplica is! String ||
      originReplica.isEmpty ||
      recordKind is! String ||
      recordKind.isEmpty ||
      recordId is! String ||
      recordId.isEmpty ||
      payload is! Map<String, Object?>) {
    throw const MemoryMirrorException('Memory log record was malformed');
  }
  return (
    sequence: _integer(value['sequence'], 'sequence'),
    originReplica: originReplica,
    recordKind: recordKind,
    recordId: recordId,
    payload: payload,
    recordedAt: _integer(value['recorded_at'], 'recorded_at'),
  );
}

MemoryMirrorPage parseMemoryMirrorPage(Map<String, Object?> body, int after) {
  final records = body['records'];
  final complete = body['complete'];
  if (records is! List || complete is! bool) {
    throw const MemoryMirrorException('Memory log page was malformed');
  }
  final parsed = records.map(_record).toList();
  var previous = after;
  for (final record in parsed) {
    if (record.sequence <= previous) {
      throw const MemoryMirrorException(
        'Memory log page was not strictly ordered',
      );
    }
    previous = record.sequence;
  }
  return (
    records: parsed,
    nextAfter: _integer(body['next_after'], 'next_after'),
    head: _integer(body['head'], 'head'),
    complete: complete,
  );
}

final class MemoryMirrorPump {
  MemoryMirrorPump({
    required this.transport,
    required this.store,
    required this.cursor,
    required this.replicaId,
    this.pageSize = 200,
    this.interval = const Duration(seconds: 30),
  });

  final MemoryMirrorTransport transport;
  final MemoryMirrorStore store;
  final PreferencesMemoryMirrorCursor cursor;
  final String replicaId;
  final int pageSize;
  final Duration interval;
  Timer? _timer;
  String? _uid;
  int _generation = 0;
  bool _running = false;

  void start(String uid) {
    if (_uid == uid && _timer != null) return;
    stop();
    _uid = uid;
    final generation = ++_generation;
    unawaited(pull(uid, generation));
    _timer = Timer.periodic(interval, (_) => unawaited(pull(uid, generation)));
  }

  void stop() {
    _generation += 1;
    _uid = null;
    _timer?.cancel();
    _timer = null;
  }

  /// Drains the log from the persisted cursor. The cursor only advances after
  /// the store has accepted the page, so an interrupted pull refetches rather
  /// than skipping records — a gap in the mirror would be a memory that exists
  /// but cannot be recalled offline.
  Future<int> pull(String uid, [int? generation]) async {
    if (_running || (generation != null && generation != _generation)) return 0;
    _running = true;
    var applied = 0;
    try {
      var after = await cursor.load(uid);
      final mirrored = await store.mirroredSequence(uid);
      if (mirrored < after) after = mirrored;
      while (generation == null || generation == _generation) {
        final page = parseMemoryMirrorPage(
          await transport.fetchLog(
            after: after,
            limit: pageSize,
            replicaId: replicaId,
          ),
          after,
        );
        if (page.records.isEmpty) break;
        await store.apply(uid, page.records);
        applied += page.records.length;
        after = page.nextAfter;
        await cursor.save(uid, after);
        if (page.complete) break;
      }
    } finally {
      _running = false;
    }
    return applied;
  }

  void dispose() => stop();
}
