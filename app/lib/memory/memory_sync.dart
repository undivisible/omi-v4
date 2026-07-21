import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/worker_http.dart';
import '../native/generated/signals/signals.dart';
import '../native/native_hub.dart';

typedef MemorySyncCursor = ({
  int requestCommit,
  int requestEventIndex,
  int appliedCommit,
  int highWaterMark,
});

abstract interface class MemorySyncCursorStore {
  Future<MemorySyncCursor> load(String uid);
  Future<void> save(String uid, MemorySyncCursor cursor);
  Future<String> replicaId();
}

final class PreferencesMemorySyncCursorStore implements MemorySyncCursorStore {
  static const _replicaKey = 'memory-sync-replica-v1';

  @override
  Future<MemorySyncCursor> load(String uid) async {
    final value = (await SharedPreferences.getInstance()).getString(
      'memory-sync-cursor-v1-$uid',
    );
    if (value == null) return _initialCursor;
    try {
      final json = jsonDecode(value);
      if (json is! Map<String, Object?>) return _initialCursor;
      final requestCommit = json['request_commit'];
      final requestEventIndex = json['request_event_index'];
      final appliedCommit = json['applied_commit'];
      final highWaterMark = json['high_water_mark'];
      if (requestCommit is! int ||
          requestEventIndex is! int ||
          appliedCommit is! int ||
          highWaterMark is! int) {
        return _initialCursor;
      }
      return (
        requestCommit: requestCommit,
        requestEventIndex: requestEventIndex,
        appliedCommit: appliedCommit,
        highWaterMark: highWaterMark,
      );
    } on FormatException {
      return _initialCursor;
    }
  }

  @override
  Future<void> save(String uid, MemorySyncCursor cursor) async {
    final saved = await (await SharedPreferences.getInstance()).setString(
      'memory-sync-cursor-v1-$uid',
      jsonEncode({
        'request_commit': cursor.requestCommit,
        'request_event_index': cursor.requestEventIndex,
        'applied_commit': cursor.appliedCommit,
        'high_water_mark': cursor.highWaterMark,
      }),
    );
    if (!saved) throw StateError('Could not persist memory sync cursor');
  }

  @override
  Future<String> replicaId() async {
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getString(_replicaKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final created = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    if (!await preferences.setString(_replicaKey, created)) {
      throw StateError('Could not persist memory replica identity');
    }
    return created;
  }
}

abstract interface class MemorySyncTransport {
  Future<Map<String, Object?>> upload(Map<String, Object?> body);
}

final class WorkerMemorySyncTransport implements MemorySyncTransport {
  const WorkerMemorySyncTransport(this._worker);

  final WorkerHttpClient _worker;

  @override
  Future<Map<String, Object?>> upload(Map<String, Object?> body) async {
    final response = await _worker.send(
      method: 'POST',
      path: '/v1/memory/zkr-sync',
      body: body,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Memory sync was rejected (${response.statusCode})');
    }
    if (response.body is! Map<String, Object?>) {
      throw StateError('Memory sync returned an invalid response');
    }
    return response.body! as Map<String, Object?>;
  }
}

final class MemorySyncPump {
  MemorySyncPump({
    required this.hub,
    required this.events,
    required this.transport,
    required this.cursorStore,
    this.interval = const Duration(seconds: 30),
  });

  final NativeHub hub;
  final Stream<NativeEvent> events;
  final MemorySyncTransport transport;
  final MemorySyncCursorStore cursorStore;
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
    unawaited(_run(uid, generation));
    _timer = Timer.periodic(interval, (_) => unawaited(_run(uid, generation)));
  }

  void stop() {
    _generation += 1;
    _uid = null;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _run(String uid, int generation) async {
    if (_running || _uid != uid || generation != _generation) return;
    _running = true;
    try {
      var cursor = await cursorStore.load(uid);
      final replicaId = await cursorStore.replicaId();
      while (_uid == uid && generation == _generation) {
        final requestId =
            'memory-export-${DateTime.now().microsecondsSinceEpoch}';
        final response = events
            .where(
              (event) =>
                  event is NativeEventMemoryExported &&
                  event.value.requestId == requestId,
            )
            .cast<NativeEventMemoryExported>()
            .map((event) => event.value)
            .first
            .timeout(const Duration(seconds: 10));
        hub.exportMemory(
          requestId: requestId,
          afterCommit: cursor.requestCommit,
          afterEventIndex: cursor.requestEventIndex,
          highWaterMark: cursor.highWaterMark == 0
              ? null
              : cursor.highWaterMark,
        );
        final page = await response;
        if (_uid != uid || generation != _generation) return;
        if (page.commits.isEmpty) break;
        final acknowledgement = await transport.upload({
          'export_format': page.exportFormat,
          'database_schema_version': page.databaseSchemaVersion,
          'replica_id': replicaId,
          'high_water_mark': page.highWaterMark,
          'commits': page.commits
              .map(
                (commit) => {
                  'sequence': commit.sequence,
                  'recorded_at': commit.recordedAtMs,
                  'event_count': commit.eventCount,
                  'first_event_index': commit.firstEventIndex,
                  'records': commit.recordsJson.map(jsonDecode).toList(),
                },
              )
              .toList(),
        });
        final statuses = acknowledgement['commits'];
        if (acknowledgement['replica_id'] != replicaId || statuses is! List) {
          throw StateError('Memory sync acknowledgement was invalid');
        }
        final bySequence = <int, String>{};
        for (final value in statuses) {
          if (value is! Map<String, Object?> ||
              value['sequence'] is! int ||
              value['status'] is! String) {
            throw StateError('Memory sync acknowledgement was invalid');
          }
          bySequence[value['sequence']! as int] = value['status']! as String;
        }
        if (page.commits.any(
          (commit) => !bySequence.containsKey(commit.sequence),
        )) {
          throw StateError('Memory sync acknowledgement was incomplete');
        }
        var applied = cursor.appliedCommit;
        for (final commit in page.commits) {
          final status = bySequence[commit.sequence];
          if (status != 'staged' &&
              status != 'applied' &&
              status != 'replayed') {
            throw StateError('Memory sync acknowledgement was invalid');
          }
          if (status == 'applied' || status == 'replayed') {
            applied = max(applied, commit.sequence);
          }
        }
        cursor = (
          requestCommit: page.nextAfterCommit,
          requestEventIndex: page.nextAfterEventIndex,
          appliedCommit: applied,
          highWaterMark: page.complete ? 0 : page.highWaterMark,
        );
        await cursorStore.save(uid, cursor);
        if (page.complete) break;
      }
    } catch (_) {
    } finally {
      _running = false;
    }
  }

  void dispose() => stop();
}

const MemorySyncCursor _initialCursor = (
  requestCommit: 0,
  requestEventIndex: -1,
  appliedCommit: 0,
  highWaterMark: 0,
);
