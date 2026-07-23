import 'package:shared_preferences/shared_preferences.dart';

/// Deliberate simplification: the "Set up Omi." checklist row on the hub is a
/// locally persisted first-run task, not a Current from the worker pipeline.
/// Seeding it through `/v1/currents` would require server-side evidence for a
/// client-only milestone, so it is stored on this device instead.
abstract interface class HubChecklistStore {
  Future<bool> isSetupComplete();

  Future<void> setSetupComplete(bool value);

  /// Starter task titles derived from the onboarding scan, shown on the hub
  /// when there is no server-side currents pipeline (local mode) or before
  /// the first generate cycle lands.
  Future<List<String>> starterTasks();

  Future<void> setStarterTasks(List<String> titles);

  Future<List<String>> doneStarterTasks();

  Future<void> setDoneStarterTasks(List<String> titles);
}

final class PreferencesHubChecklistStore implements HubChecklistStore {
  static const _key = 'hub_setup_omi_complete_v1';
  static const _starterKey = 'hub_starter_tasks_v1';
  static const _doneStarterKey = 'hub_starter_tasks_done_v1';

  @override
  Future<bool> isSetupComplete() async =>
      (await SharedPreferences.getInstance()).getBool(_key) ?? true;

  @override
  Future<void> setSetupComplete(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(_key, value);
  }

  @override
  Future<List<String>> starterTasks() async =>
      (await SharedPreferences.getInstance()).getStringList(_starterKey) ??
      const [];

  @override
  Future<void> setStarterTasks(List<String> titles) async {
    await (await SharedPreferences.getInstance()).setStringList(
      _starterKey,
      titles,
    );
  }

  @override
  Future<List<String>> doneStarterTasks() async =>
      (await SharedPreferences.getInstance()).getStringList(_doneStarterKey) ??
      const [];

  @override
  Future<void> setDoneStarterTasks(List<String> titles) async {
    await (await SharedPreferences.getInstance()).setStringList(
      _doneStarterKey,
      titles,
    );
  }
}

final class VolatileHubChecklistStore implements HubChecklistStore {
  VolatileHubChecklistStore({this.setupComplete = true});

  bool setupComplete;
  List<String> tasks = const [];
  List<String> doneTasks = const [];

  @override
  Future<bool> isSetupComplete() async => setupComplete;

  @override
  Future<void> setSetupComplete(bool value) async => setupComplete = value;

  @override
  Future<List<String>> starterTasks() async => tasks;

  @override
  Future<void> setStarterTasks(List<String> titles) async =>
      tasks = List.of(titles);

  @override
  Future<List<String>> doneStarterTasks() async => doneTasks;

  @override
  Future<void> setDoneStarterTasks(List<String> titles) async =>
      doneTasks = List.of(titles);
}
