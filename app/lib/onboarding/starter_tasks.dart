import '../native/generated/signals/signals.dart' show OnboardingScanSource;

/// Derives 2–4 starter task titles from the on-device scan results: the
/// emphasized spans of the scan summary (project and thread names the model
/// called out) plus the scanned sources that actually produced evidence.
/// Returns an empty list when the scan produced nothing usable — callers
/// must treat that as "no starter tasks", never substitute canned ones.
List<String> deriveStarterTasks({
  String? summary,
  List<OnboardingScanSource> sources = const [],
}) {
  final subjects = <String>[];
  if (summary != null) {
    final spans = RegExp(r'\*\*([^*]+)\*\*').allMatches(summary);
    for (final span in spans) {
      final subject = span.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (subject.length < 3 || subject.length > 60) continue;
      if (subjects.any((existing) => existing.toLowerCase() == subject.toLowerCase())) {
        continue;
      }
      subjects.add(subject);
    }
  }
  const templates = [
    'Pick “{}” back up where you left off.',
    'Decide the next step for “{}”.',
    'Tie up the loose ends in “{}”.',
  ];
  final tasks = <String>[
    for (final (index, subject) in subjects.indexed.take(templates.length))
      templates[index].replaceFirst('{}', subject),
  ];
  if (tasks.length < 4) {
    for (final source in sources) {
      if (tasks.length >= 4) break;
      final items = source.itemsFound.toBigInt();
      if (items <= BigInt.zero) continue;
      final name = source.source.replaceAll('_', ' ').trim();
      if (name.isEmpty) continue;
      tasks.add(
        'Go through the $items ${items == BigInt.one ? 'item' : 'items'} '
        'I found in your $name.',
      );
    }
  }
  return List.unmodifiable(tasks.take(4));
}
