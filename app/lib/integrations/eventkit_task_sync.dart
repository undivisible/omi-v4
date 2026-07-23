import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../currents/currents.dart';
import 'apple_eventkit.dart';

const _eventWindowLimit = Duration(hours: 24);

@immutable
final class EventKitTrackedItem {
  const EventKitTrackedItem({required this.source, required this.nativeId});

  factory EventKitTrackedItem.fromJson(Map<String, Object?> json) =>
      EventKitTrackedItem(
        source: AppleEventKitSource.values.byName(json['source']! as String),
        nativeId: json['nativeId']! as String,
      );

  final AppleEventKitSource source;
  final String nativeId;

  Map<String, Object?> toJson() => {
    'source': source.name,
    'nativeId': nativeId,
  };
}

abstract interface class EventKitTaskSyncStore {
  Future<bool> enabled();

  Future<void> setEnabled(bool value);

  Future<Map<String, EventKitTrackedItem>> trackedItems();

  Future<void> saveTrackedItems(Map<String, EventKitTrackedItem> items);
}

final class PreferencesEventKitTaskSyncStore implements EventKitTaskSyncStore {
  static const _enabledKey = 'omi_eventkit_task_sync_enabled_v1';
  static const _itemsKey = 'omi_eventkit_task_sync_items_v1';

  @override
  Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(_enabledKey) ?? false;

  @override
  Future<void> setEnabled(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(_enabledKey, value);
  }

  @override
  Future<Map<String, EventKitTrackedItem>> trackedItems() async {
    final raw = (await SharedPreferences.getInstance()).getString(_itemsKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      return {
        for (final entry in decoded.entries)
          entry.key: EventKitTrackedItem.fromJson(
            entry.value! as Map<String, Object?>,
          ),
      };
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> saveTrackedItems(Map<String, EventKitTrackedItem> items) async {
    await (await SharedPreferences.getInstance()).setString(
      _itemsKey,
      jsonEncode({
        for (final entry in items.entries) entry.key: entry.value.toJson(),
      }),
    );
  }
}

final class VolatileEventKitTaskSyncStore implements EventKitTaskSyncStore {
  VolatileEventKitTaskSyncStore({this.isEnabled = false});

  bool isEnabled;
  Map<String, EventKitTrackedItem> items = {};

  @override
  Future<bool> enabled() async => isEnabled;

  @override
  Future<void> setEnabled(bool value) async => isEnabled = value;

  @override
  Future<Map<String, EventKitTrackedItem>> trackedItems() async =>
      Map.of(items);

  @override
  Future<void> saveTrackedItems(Map<String, EventKitTrackedItem> next) async =>
      items = Map.of(next);
}

final class EventKitTaskSync {
  EventKitTaskSync({required this.writer, required this.store});

  static EventKitTaskSync? platformDefault() =>
      !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.iOS)
      ? EventKitTaskSync(
          writer: AppleEventKitService(),
          store: PreferencesEventKitTaskSyncStore(),
        )
      : null;

  final AppleEventKitWriter writer;
  final EventKitTaskSyncStore store;
  Future<void> _queue = Future.value();

  Future<void> apply(List<CurrentCard> cards) {
    final operation = _queue.then(
      (_) => _apply(cards),
      onError: (Object _) => _apply(cards),
    );
    _queue = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<void> _apply(List<CurrentCard> cards) async {
    if (!writer.available || !await store.enabled()) return;
    final tracked = await store.trackedItems();
    final grants = <AppleEventKitSource, bool>{};
    Future<bool> granted(AppleEventKitSource source) async => grants[source] ??=
        await writer.status(source) == AppleEventKitAuthorization.fullAccess;
    final active = <String, CurrentCard>{
      for (final card in cards)
        if (!card.item.isTerminal) card.item.id: card,
    };
    for (final card in active.values) {
      final id = card.item.id;
      final expiresAt = card.item.timing.expiresAt;
      if (expiresAt == null) continue;
      final surfaceAt = card.item.timing.surfaceAt;
      final source = expiresAt.difference(surfaceAt) <= _eventWindowLimit
          ? AppleEventKitSource.calendar
          : AppleEventKitSource.reminders;
      if (!await granted(source)) continue;
      final existing = tracked[id];
      if (existing != null && existing.source != source) {
        try {
          await writer.removeItem(existing.source, existing.nativeId);
        } catch (_) {}
        tracked.remove(id);
      }
      try {
        final nativeId = await writer.upsertItem(
          source: source,
          currentId: id,
          title: card.title,
          notes: '${card.summary}\nomi-current:$id',
          nativeId: existing?.source == source ? existing?.nativeId : null,
          startAt: source == AppleEventKitSource.calendar ? surfaceAt : null,
          endAt: source == AppleEventKitSource.calendar ? expiresAt : null,
          dueAt: source == AppleEventKitSource.reminders ? expiresAt : null,
        );
        if (nativeId != null) {
          tracked[id] = EventKitTrackedItem(source: source, nativeId: nativeId);
        }
      } catch (_) {}
    }
    for (final id in tracked.keys.toList()) {
      if (active.containsKey(id)) continue;
      final item = tracked[id]!;
      if (!await granted(item.source)) continue;
      try {
        if (item.source == AppleEventKitSource.reminders) {
          await writer.completeItem(item.source, item.nativeId);
        } else {
          await writer.removeItem(item.source, item.nativeId);
        }
        tracked.remove(id);
      } catch (_) {}
    }
    await store.saveTrackedItems(tracked);
  }
}
