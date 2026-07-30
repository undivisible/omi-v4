import 'package:shared_preferences/shared_preferences.dart';

/// How long starter tasks stay on the hub before they retire themselves.
///
/// They are scaffolding for a first run with no memory behind it, derived from
/// one onboarding scan and never regenerated. Left alone they read as stale
/// suggestions Omi keeps repeating, which is worse than an empty hub — so they
/// expire on their own even if the currents pipeline never produces anything
/// to replace them.
const starterTaskLifetime = Duration(days: 7);

/// Deliberate simplification: the "Set up Omi." checklist row on the hub is a
/// locally persisted first-run task, not a Current from the worker pipeline.
/// Seeding it through `/v1/currents` would require server-side evidence for a
/// client-only milestone, so it is stored on this device instead.
abstract interface class HubChecklistStore {
  Future<bool> isSetupComplete();

  Future<void> setSetupComplete(bool value);

  /// Starter task titles derived from the onboarding scan, shown on the hub
  /// when there is no server-side currents pipeline (local mode) or before
  /// the first generate cycle lands. Empty once [starterTaskLifetime] has
  /// passed since they were written, or once [clearStarterTasks] retires them.
  Future<List<String>> starterTasks();

  Future<void> setStarterTasks(List<String> titles);

  /// Retires the starter tasks for good. Called when real currents arrive:
  /// they were only ever a stand-in for these.
  Future<void> clearStarterTasks();

  Future<List<String>> doneStarterTasks();

  Future<void> setDoneStarterTasks(List<String> titles);
}

final class PreferencesHubChecklistStore implements HubChecklistStore {
  PreferencesHubChecklistStore({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const _key = 'hub_setup_omi_complete_v1';
  static const _starterKey = 'hub_starter_tasks_v1';
  static const _starterWrittenKey = 'hub_starter_tasks_written_at_v1';
  static const _doneStarterKey = 'hub_starter_tasks_done_v1';

  final DateTime Function() _now;

  @override
  Future<bool> isSetupComplete() async =>
      (await SharedPreferences.getInstance()).getBool(_key) ?? true;

  @override
  Future<void> setSetupComplete(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(_key, value);
  }

  @override
  Future<List<String>> starterTasks() async {
    final preferences = await SharedPreferences.getInstance();
    final titles = preferences.getStringList(_starterKey) ?? const [];
    if (titles.isEmpty) return const [];
    // Tasks written before the stamp existed have no known age. Treat them as
    // expired rather than immortal: an upgrade is exactly the case where they
    // have been sitting on the hub longest.
    final written = preferences.getInt(_starterWrittenKey);
    if (written == null) {
      await _forgetStarterTasks(preferences);
      return const [];
    }
    final age = _now().difference(
      DateTime.fromMillisecondsSinceEpoch(written),
    );
    if (age >= starterTaskLifetime || age.isNegative) {
      await _forgetStarterTasks(preferences);
      return const [];
    }
    return titles;
  }

  @override
  Future<void> setStarterTasks(List<String> titles) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(_starterKey, titles);
    await preferences.setInt(
      _starterWrittenKey,
      _now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> clearStarterTasks() async =>
      _forgetStarterTasks(await SharedPreferences.getInstance());

  /// Drops the titles, their stamp and their done-set together. Leaving the
  /// done-set behind would keep a retired title marked complete if the same
  /// text were ever derived again.
  Future<void> _forgetStarterTasks(SharedPreferences preferences) async {
    await preferences.remove(_starterKey);
    await preferences.remove(_starterWrittenKey);
    await preferences.remove(_doneStarterKey);
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
  Future<void> clearStarterTasks() async {
    tasks = const [];
    doneTasks = const [];
  }

  @override
  Future<List<String>> doneStarterTasks() async => doneTasks;

  @override
  Future<void> setDoneStarterTasks(List<String> titles) async =>
      doneTasks = List.of(titles);
}
