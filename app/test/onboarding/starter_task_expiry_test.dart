import 'package:flutter_test/flutter_test.dart';
import 'package:omi/onboarding/hub_checklist.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime clock;
  PreferencesHubChecklistStore store() =>
      PreferencesHubChecklistStore(now: () => clock);

  setUp(() {
    clock = DateTime(2026, 7, 27);
    SharedPreferences.setMockInitialValues({});
  });

  test('starter tasks survive until the lifetime is up', () async {
    await store().setStarterTasks(['Open “omi” and write down its next step.']);

    clock = clock.add(starterTaskLifetime - const Duration(hours: 1));

    expect(await store().starterTasks(), hasLength(1));
  });

  test('starter tasks retire themselves once the lifetime passes', () async {
    await store().setStarterTasks(['Open “omi” and write down its next step.']);
    await store().setDoneStarterTasks([
      'Open “omi” and write down its next step.',
    ]);

    clock = clock.add(starterTaskLifetime);

    expect(await store().starterTasks(), isEmpty);
    // The done-set goes with them, so a title that is derived again later does
    // not come back already ticked.
    expect(await store().doneStarterTasks(), isEmpty);
  });

  test('a clock that moves backwards expires rather than extends', () async {
    await store().setStarterTasks(['Set a concrete deadline for “omi”.']);

    clock = clock.subtract(const Duration(days: 1));

    expect(await store().starterTasks(), isEmpty);
  });

  test('tasks written before the stamp existed are treated as expired', () async {
    SharedPreferences.setMockInitialValues({
      'hub_starter_tasks_v1': ['Archive “omi” or schedule its next session.'],
    });

    expect(await store().starterTasks(), isEmpty);
  });

  test('clearStarterTasks retires them immediately', () async {
    await store().setStarterTasks(['Set a concrete deadline for “omi”.']);
    expect(await store().starterTasks(), hasLength(1));

    await store().clearStarterTasks();

    expect(await store().starterTasks(), isEmpty);
  });

  test('rewriting the tasks restarts the lifetime', () async {
    await store().setStarterTasks(['Set a concrete deadline for “omi”.']);

    clock = clock.add(starterTaskLifetime - const Duration(hours: 1));
    await store().setStarterTasks(['Open “omi” and write down its next step.']);
    clock = clock.add(const Duration(hours: 2));

    expect(await store().starterTasks(), hasLength(1));
  });
}
