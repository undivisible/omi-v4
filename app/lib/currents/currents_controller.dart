import 'dart:async';

import 'package:flutter/foundation.dart';

import '../native/native_hub.dart';
import 'currents.dart';

/// How long the client waits for the hub to compose the brief before giving up
/// on it. The hub caps its own model call well below this; the ceiling here
/// only exists so a hub that never answers cannot leak a pending composition.
const _composeTimeout = Duration(seconds: 30);

final class CurrentsController extends ChangeNotifier {
  CurrentsController(
    this._client, {
    this.onItemsRefreshed,
    this.hub,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final CurrentsClient _client;
  final Future<void> Function(List<CurrentCard> items)? onItemsRefreshed;

  /// The hub the brief is composed by. Null, or unavailable, simply means the
  /// brief is never composed and the hand-built one renders.
  final NativeHub? hub;
  final DateTime Function() _now;
  List<CurrentCard> items = const [];
  String? error;
  bool loading = false;
  Future<void>? _loadFuture;
  int _composeGeneration = 0;

  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      await _client.generate();
      items = await _client.list();
      _notifyItemsRefreshed();
      _composeBrief();
    } on CurrentsClientException catch (failure) {
      error = failure.message;
    } finally {
      loading = false;
      _loadFuture = null;
      notifyListeners();
    }
  }

  Future<void> dismiss(String id) => _feedback(id, CurrentStatus.dismissed);

  Future<void> snooze(String id, DateTime until) =>
      _feedback(id, CurrentStatus.snoozed, snoozedUntil: until);

  Future<CurrentActionHandoff> accept(String id) => _client.accept(id);

  Future<void> _feedback(
    String id,
    CurrentStatus status, {
    DateTime? snoozedUntil,
  }) async {
    await _client.feedback(id, status, snoozedUntil: snoozedUntil);
    items = List.unmodifiable(items.where((item) => item.item.id != id));
    _notifyItemsRefreshed();
    notifyListeners();
  }

  void _notifyItemsRefreshed() {
    final hook = onItemsRefreshed;
    if (hook == null) return;
    unawaited(hook(items).catchError((Object _) {}));
  }

  /// Asks the hub to compose the brief for the currents just refreshed, and
  /// attaches whatever comes back to the hero card.
  ///
  /// Deliberately not awaited: the refresh is finished and on screen before the
  /// model is asked, and a brief that never arrives changes nothing. Every
  /// failure — no hub, no generator configured, a model error, a timeout, a
  /// superseded refresh, or a document the renderer would refuse — leaves the
  /// hand-built brief exactly as it is.
  void _composeBrief() {
    final hub = this.hub;
    if (hub == null || !hub.available) return;
    final generation = ++_composeGeneration;
    final plan = planBrief(items, now: _now());
    final hero = plan.hero;
    if (hero == null) return;
    unawaited(
      _requestBrief(hub, [hero, ...plan.rest])
          .then((crepus) {
            if (crepus == null || generation != _composeGeneration) return;
            _attachCrepus(hero.card.item.id, crepus);
          })
          .catchError((Object _) {}),
    );
  }

  Future<String?> _requestBrief(NativeHub hub, List<BriefEntry> entries) {
    final requestId =
        'brief-$_composeGeneration-'
        '${_now().microsecondsSinceEpoch}';
    final answered = hub.events
        .where(
          (event) =>
              event is NativeEventBriefComposed &&
              event.value.requestId == requestId,
        )
        .cast<NativeEventBriefComposed>()
        .map((event) => event.value.crepus)
        .first
        .timeout(_composeTimeout);
    hub.composeBrief(
      requestId: requestId,
      nowLocal: _formatNow(_now()),
      items: [
        for (final entry in entries)
          BriefItem(
            title: entry.title,
            when: entry.meta?.formatTimeRange() ?? '',
            detail: entry.detail ?? '',
            nextStep: entry.card.item.proposedNextStep,
          ),
      ],
    );
    return answered;
  }

  /// Replaces the hero card with one carrying the composed document in its
  /// metadata, which is where `currentCrepusSource` reads it from.
  void _attachCrepus(String id, String crepus) {
    if (!items.any((card) => card.item.id == id)) return;
    items = List.unmodifiable([
      for (final card in items)
        if (card.item.id != id)
          card
        else
          CurrentCard(
            item: card.item,
            title: card.title,
            summary: card.summary,
            sourceKind: card.sourceKind,
            metadata: {...?card.metadata, 'crepus': crepus},
          ),
    ]);
    notifyListeners();
  }
}

/// The local time, in the voice the brief prompt asks for: "Thursday 9:00 AM".
String _formatNow(DateTime now) {
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
  final minute = now.minute.toString().padLeft(2, '0');
  final period = now.hour < 12 ? 'AM' : 'PM';
  return '${weekdays[now.weekday - 1]} $hour:$minute $period';
}
