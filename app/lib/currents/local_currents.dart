import 'dart:async';

import '../native/native_hub.dart';
import 'currents.dart';

/// How long the local source waits for the hub to answer with memory items.
const _listTimeout = Duration(seconds: 10);

/// How many memory items are read, and how many of them become currents.
const _listLimit = 24;
const _maxLocalCurrents = 4;

/// Currents built from the hub's own memory store, for a hub with no account
/// to sync against. The worker composes richer currents from synced memory,
/// but a local store still knows what was recently captured, and that is a
/// truer answer than an apology.
final class LocalCurrentsSource {
  LocalCurrentsSource(this._hub, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final NativeHub? _hub;
  final DateTime Function() _now;
  int _generation = 0;

  /// The currents the local store yields, or null when it could not be read
  /// at all — an absent or unavailable hub, or one that never answers. Null is
  /// not the same answer as an empty store, which genuinely has nothing yet.
  Future<List<CurrentCard>?> load() async {
    final hub = _hub;
    if (hub == null || !hub.available) return null;
    final requestId = 'local-currents-${++_generation}-'
        '${_now().microsecondsSinceEpoch}';
    final answered = hub.events
        .where(
          (event) =>
              event is NativeEventMemoryItems &&
              event.value.requestId == requestId,
        )
        .cast<NativeEventMemoryItems>()
        .map((event) => event.value.items)
        .first
        .timeout(_listTimeout);
    hub.listMemoryItems(requestId: requestId, limit: _listLimit);
    final List<MemoryItem> items;
    try {
      items = await answered;
    } on Object {
      return null;
    }
    return _toCards(items, _now());
  }
}

List<CurrentCard> _toCards(List<MemoryItem> items, DateTime now) {
  final usable =
      items.where((item) => _headline(item).isNotEmpty).toList()
        ..sort((a, b) => b.recordedAtMs.compareTo(a.recordedAtMs));
  final chosen = usable.take(_maxLocalCurrents).toList();
  return List.unmodifiable([
    for (var index = 0; index < chosen.length; index += 1)
      _toCard(chosen[index], index, now),
  ]);
}

CurrentCard _toCard(MemoryItem item, int index, DateTime now) {
  final recordedAt = DateTime.fromMillisecondsSinceEpoch(
    item.recordedAtMs,
    isUtc: true,
  );
  final createdAt = recordedAt.isAfter(now) ? now : recordedAt;
  final headline = _headline(item);
  final summary = _summary(item, headline);
  return CurrentCard(
    item: CurrentItem.candidate(
      id: 'local:${item.id}',
      evidence: [
        CurrentEvidence(
          sourceId: item.id,
          reason: item.kind.isEmpty ? 'local memory' : item.kind,
        ),
      ],
      reason: 'Captured on this device.',
      timing: CurrentTiming(surfaceAt: createdAt),
      // Ordered by recency, so the newest memory leads the brief without ever
      // claiming the confidence a scored server-side current would carry.
      confidence: 0.5 - index * 0.05,
      proposedNextStep: 'Ask Omi about this.',
      createdAt: createdAt,
    ),
    title: headline,
    summary: summary,
    sourceKind: item.kind.isEmpty ? 'local' : item.kind,
    contentKind: CurrentContentKind.awareness,
  );
}

String _headline(MemoryItem item) {
  final title = item.title.trim();
  if (title.isNotEmpty) return _clip(title, 120);
  final firstLine = item.body
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  return _clip(firstLine, 120);
}

String _summary(MemoryItem item, String headline) {
  final body = item.body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (body.isEmpty || body == headline) return '';
  return _clip(body, 220);
}

String _clip(String value, int max) =>
    value.length <= max ? value : '${value.substring(0, max - 1).trimRight()}…';
