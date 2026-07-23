import 'package:flutter_test/flutter_test.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/onboarding/starter_tasks.dart';

OnboardingScanSource _source(String source, int items) => OnboardingScanSource(
  source: source,
  state: OnboardingScanState.complete,
  itemsFound: Uint64.fromBigInt(BigInt.from(items)),
  detail: '',
);

void main() {
  test('derives tasks from emphasized project and thread names', () {
    final tasks = deriveStarterTasks(
      summary:
          'You keep **Alpenglow** moving while a decision about the '
          '**desktop handoff** waits in **Friday planning**.',
    );
    expect(tasks, hasLength(3));
    expect(tasks[0], contains('Alpenglow'));
    expect(tasks[1], contains('desktop handoff'));
    expect(tasks[2], contains('Friday planning'));
    expect(tasks[0], contains('write down its single next step'));
    expect(tasks[1], contains('deadline'));
    for (final task in tasks) {
      expect(task, isNot(contains('loose ends')));
      expect(task, matches(RegExp(r'^(Open|Set|Archive|Review) ')));
    }
  });

  test('drops vague subjects that cannot be made concrete', () {
    expect(
      deriveStarterTasks(summary: 'Tie up **loose ends** across **stuff**.'),
      isEmpty,
    );
    final tasks = deriveStarterTasks(
      summary: 'You juggle **misc** and **Alpenglow**.',
    );
    expect(tasks, hasLength(1));
    expect(tasks.single, contains('Alpenglow'));
  });

  test('skips vague source names in the evidence fallback', () {
    final tasks = deriveStarterTasks(
      summary: null,
      sources: [_source('other', 8), _source('apple_mail', 3)],
    );
    expect(tasks, hasLength(1));
    expect(tasks.single, contains('apple mail'));
    expect(tasks.single, contains('3'));
  });

  test('falls back to scanned sources with evidence and caps at four', () {
    final tasks = deriveStarterTasks(
      summary: 'You work on **Alpenglow**.',
      sources: [
        _source('workspace', 12),
        _source('apple_notes', 0),
        _source('apple_mail', 3),
        _source('calendar', 9),
        _source('files', 2),
      ],
    );
    expect(tasks, hasLength(4));
    expect(tasks[0], contains('Alpenglow'));
    expect(tasks[1], contains('12'));
    expect(tasks[1], contains('workspace'));
    expect(tasks.join(), isNot(contains('apple_notes')));
    expect(tasks[2], contains('apple mail'));
  });

  test('deduplicates subjects and returns nothing without evidence', () {
    expect(deriveStarterTasks(summary: null), isEmpty);
    expect(deriveStarterTasks(summary: 'Nothing emphasized here.'), isEmpty);
    final tasks = deriveStarterTasks(
      summary: '**Alpenglow** and again **alpenglow**.',
    );
    expect(tasks, hasLength(1));
  });
}
