import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../native/native_hub.dart';
import 'apple_eventkit.dart';

typedef EventKitRecordedAt =
    Future<int> Function(String personId, AppleEventKitItem item);

final class AppleEventKitImportCoordinator {
  factory AppleEventKitImportCoordinator({
    required AppleEventKitService eventKit,
    required NativeHub hub,
    required String personId,
    String Function()? requestId,
    EventKitRecordedAt? recordedAt,
  }) => AppleEventKitImportCoordinator._(
    eventKit,
    hub,
    personId,
    requestId ?? _defaultRequestId,
    recordedAt ?? _persistedRecordedAt,
  );

  AppleEventKitImportCoordinator._(
    this._eventKit,
    this._hub,
    this._personId,
    this._requestId,
    this._recordedAt,
  );

  final AppleEventKitService _eventKit;
  final NativeHub _hub;
  final String _personId;
  final String Function() _requestId;
  final EventKitRecordedAt _recordedAt;

  Future<int> import(
    AppleEventKitSource source, {
    int limit = 200,
    int daysBack = 365,
    int daysForward = 30,
  }) async {
    final items = await _eventKit.read(
      source,
      limit: limit,
      daysBack: daysBack,
      daysForward: daysForward,
    );
    for (final item in items) {
      final recordedAtMs = await _recordedAt(_personId, item);
      _hub.capture(
        requestId: _requestId(),
        ingestionKey:
            'eventkit:${item.source.name}:${item.nativeId}:$recordedAtMs',
        source: switch (item.source) {
          AppleEventKitSource.calendar => CaptureSource.appleCalendar,
          AppleEventKitSource.reminders => CaptureSource.appleReminders,
        },
        occurredAtMs: item.occurredAt.millisecondsSinceEpoch,
        recordedAtMs: recordedAtMs,
        text: item.memoryText,
      );
    }
    return items.length;
  }

  static String _defaultRequestId() =>
      'eventkit-${DateTime.now().microsecondsSinceEpoch}';

  static Future<int> _persistedRecordedAt(
    String personId,
    AppleEventKitItem item,
  ) async {
    final revision = sha256.convert(
      utf8.encode(
        [
          item.id,
          item.title,
          item.notes,
          item.calendar,
          item.occurredAt.toIso8601String(),
          item.startAt?.toIso8601String() ?? '',
          item.endAt?.toIso8601String() ?? '',
          item.dueAt?.toIso8601String() ?? '',
          item.location,
          item.isAllDay.toString(),
          item.isCompleted.toString(),
        ].join('\u001f'),
      ),
    );
    final key =
        'eventkit_recorded_at_${sha256.convert(utf8.encode('$personId:$revision'))}';
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getInt(key);
    if (existing != null) return existing;
    final value = item.recordedAt.millisecondsSinceEpoch;
    if (!await preferences.setInt(key, value)) {
      throw StateError('Could not persist EventKit observation time.');
    }
    return value;
  }
}
