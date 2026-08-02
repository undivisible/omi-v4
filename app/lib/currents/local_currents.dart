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
    final requestId =
        'local-currents-${++_generation}-'
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
  final usable = items.where((item) => _headline(item).isNotEmpty).toList()
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
  final day = _dayLabel(item, createdAt);
  final sourceKind = _sourceKind(item);
  return CurrentCard(
    item: CurrentItem.candidate(
      id: 'local:${item.id}',
      evidence: [
        CurrentEvidence(sourceId: item.id, reason: _provenance(item, day)),
      ],
      reason: 'Captured on this device.',
      timing: CurrentTiming(surfaceAt: createdAt),
      // Ordered by recency, so the newest memory leads the brief without ever
      // claiming the confidence a scored server-side current would carry.
      confidence: 0.5 - index * 0.05,
      // A remembered thing is not a task. The local store knows what was
      // captured, not what to do about it, and a card with no genuine step
      // shows no action rather than inventing one.
      proposedNextStep: '',
      createdAt: createdAt,
    ),
    title: headline,
    summary: summary,
    sourceKind: sourceKind,
    contentKind: CurrentContentKind.awareness,
    metadata: {
      'kind': sourceKind ?? 'memory',
      'title': headline,
      'detail': ?day,
    },
  );
}

/// The date a memory item names in its own title, for the kinds that title
/// themselves by day rather than by what happened.
DateTime? _titledDay(MemoryItem item) {
  final title = item.title.trim();
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(title)) return null;
  return DateTime.tryParse('${title}T00:00:00Z');
}

String? _dayLabel(MemoryItem item, DateTime createdAt) {
  final day = _titledDay(item) ?? createdAt;
  if (day.millisecondsSinceEpoch <= 0) return null;
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${day.day} ${months[day.month - 1]}';
}

String? _sourceKind(MemoryItem item) {
  final kind = item.kind.trim();
  if (kind.isEmpty) return null;
  return kind.replaceAll('_', ' ');
}

/// Where the item came from, said the way a person would say it. Never an
/// identifier: an id tells the reader nothing they can act on or recognise.
String _provenance(MemoryItem item, String? day) {
  final kind = _sourceKind(item);
  final where = kind == null ? 'Captured on this device' : 'From your $kind';
  return day == null ? where : '$where, $day';
}

String _headline(MemoryItem item) {
  final title = item.title.trim();
  if (title.isNotEmpty && _titledDay(item) == null) return _clip(title, 120);
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
