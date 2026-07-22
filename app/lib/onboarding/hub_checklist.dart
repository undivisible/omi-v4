import 'package:shared_preferences/shared_preferences.dart';

/// Deliberate simplification: the "Set up Omi." checklist row on the hub is a
/// locally persisted first-run task, not a Current from the worker pipeline.
/// Seeding it through `/v1/currents` would require server-side evidence for a
/// client-only milestone, so it is stored on this device instead.
abstract interface class HubChecklistStore {
  Future<bool> isSetupComplete();

  Future<void> setSetupComplete(bool value);
}

final class PreferencesHubChecklistStore implements HubChecklistStore {
  static const _key = 'hub_setup_omi_complete_v1';

  @override
  Future<bool> isSetupComplete() async =>
      (await SharedPreferences.getInstance()).getBool(_key) ?? true;

  @override
  Future<void> setSetupComplete(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(_key, value);
  }
}

final class VolatileHubChecklistStore implements HubChecklistStore {
  VolatileHubChecklistStore({this.setupComplete = true});

  bool setupComplete;

  @override
  Future<bool> isSetupComplete() async => setupComplete;

  @override
  Future<void> setSetupComplete(bool value) async => setupComplete = value;
}
