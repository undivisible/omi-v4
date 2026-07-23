import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum AppleEventKitSource { calendar, reminders }

enum AppleEventKitAuthorization {
  notDetermined,
  restricted,
  denied,
  writeOnly,
  fullAccess,
  unavailable,
}

@immutable
final class AppleEventKitItem {
  const AppleEventKitItem({
    required this.id,
    required this.nativeId,
    required this.source,
    required this.title,
    required this.notes,
    required this.calendar,
    required this.occurredAt,
    required this.recordedAt,
    this.startAt,
    this.endAt,
    this.dueAt,
    this.location = '',
    this.isAllDay = false,
    this.isCompleted = false,
  });

  factory AppleEventKitItem.fromMap(Map<Object?, Object?> value) {
    DateTime requiredTime(String key) =>
        DateTime.parse(value[key]! as String).toUtc();
    DateTime? optionalTime(String key) {
      final raw = value[key];
      return raw is String ? DateTime.parse(raw).toUtc() : null;
    }

    return AppleEventKitItem(
      id: value['id']! as String,
      nativeId: value['nativeId']! as String,
      source: AppleEventKitSource.values.byName(value['source']! as String),
      title: value['title']! as String,
      notes: value['notes']! as String,
      calendar: value['calendar']! as String,
      occurredAt: requiredTime('occurredAt'),
      recordedAt: requiredTime('recordedAt'),
      startAt: optionalTime('startAt'),
      endAt: optionalTime('endAt'),
      dueAt: optionalTime('dueAt'),
      location: value['location'] as String? ?? '',
      isAllDay: value['isAllDay'] as bool? ?? false,
      isCompleted: value['isCompleted'] as bool? ?? false,
    );
  }

  final String id;
  final String nativeId;
  final AppleEventKitSource source;
  final String title;
  final String notes;
  final String calendar;
  final DateTime occurredAt;
  final DateTime recordedAt;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? dueAt;
  final String location;
  final bool isAllDay;
  final bool isCompleted;

  String get memoryText {
    final parts = <String>[
      source == AppleEventKitSource.calendar
          ? 'Apple Calendar event: $title'
          : 'Apple Reminder: $title',
      if (startAt != null) 'Starts: ${startAt!.toIso8601String()}',
      if (dueAt != null) 'Due: ${dueAt!.toIso8601String()}',
      if (location.isNotEmpty) 'Location: $location',
      if (notes.isNotEmpty) 'Notes: $notes',
    ];
    return parts.join(' | ');
  }
}

abstract interface class AppleEventKitWriter {
  bool get available;

  Future<AppleEventKitAuthorization> status(AppleEventKitSource source);

  Future<AppleEventKitAuthorization> request(AppleEventKitSource source);

  Future<String?> upsertItem({
    required AppleEventKitSource source,
    required String currentId,
    required String title,
    required String notes,
    String? nativeId,
    DateTime? startAt,
    DateTime? endAt,
    DateTime? dueAt,
  });

  Future<void> completeItem(AppleEventKitSource source, String nativeId);

  Future<void> removeItem(AppleEventKitSource source, String nativeId);
}

final class AppleEventKitService implements AppleEventKitWriter {
  factory AppleEventKitService({MethodChannel? channel, bool? available}) =>
      AppleEventKitService._(
        channel ?? const MethodChannel('omi/apple_eventkit'),
        available,
      );

  AppleEventKitService._(this._channel, this._available);

  final MethodChannel _channel;
  final bool? _available;

  @override
  bool get available =>
      _available ??
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.iOS));

  @override
  Future<AppleEventKitAuthorization> status(AppleEventKitSource source) async {
    if (!available) return AppleEventKitAuthorization.unavailable;
    final result = await _channel.invokeMapMethod<String, Object?>('status', {
      'source': source.name,
    });
    return _authorization(result?['status']);
  }

  @override
  Future<AppleEventKitAuthorization> request(AppleEventKitSource source) async {
    if (!available) return AppleEventKitAuthorization.unavailable;
    final result = await _channel.invokeMapMethod<String, Object?>('request', {
      'source': source.name,
    });
    return _authorization(result?['status']);
  }

  Future<List<AppleEventKitItem>> read(
    AppleEventKitSource source, {
    int limit = 200,
    int daysBack = 365,
    int daysForward = 30,
  }) async {
    if (!available) return const [];
    final rows = await _channel.invokeListMethod<Object?>('read', {
      'source': source.name,
      'limit': limit.clamp(1, 2500),
      'daysBack': daysBack.clamp(0, 3650),
      'daysForward': daysForward.clamp(0, 3650),
    });
    return List.unmodifiable(
      (rows ?? const []).map(
        (row) => AppleEventKitItem.fromMap(row! as Map<Object?, Object?>),
      ),
    );
  }

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
    if (!available) return null;
    final result = await _channel
        .invokeMapMethod<String, Object?>('upsertItem', {
          'source': source.name,
          'currentId': currentId,
          'title': title,
          'notes': notes,
          'nativeId': nativeId,
          'startAt': startAt?.toUtc().toIso8601String(),
          'endAt': endAt?.toUtc().toIso8601String(),
          'dueAt': dueAt?.toUtc().toIso8601String(),
        });
    return result?['nativeId'] as String?;
  }

  @override
  Future<void> completeItem(AppleEventKitSource source, String nativeId) async {
    if (!available) return;
    await _channel.invokeMapMethod<String, Object?>('completeItem', {
      'source': source.name,
      'nativeId': nativeId,
    });
  }

  @override
  Future<void> removeItem(AppleEventKitSource source, String nativeId) async {
    if (!available) return;
    await _channel.invokeMapMethod<String, Object?>('removeItem', {
      'source': source.name,
      'nativeId': nativeId,
    });
  }

  AppleEventKitAuthorization _authorization(Object? value) => switch (value) {
    'not_determined' => AppleEventKitAuthorization.notDetermined,
    'restricted' => AppleEventKitAuthorization.restricted,
    'denied' => AppleEventKitAuthorization.denied,
    'write_only' => AppleEventKitAuthorization.writeOnly,
    'full_access' => AppleEventKitAuthorization.fullAccess,
    _ => AppleEventKitAuthorization.unavailable,
  };
}
