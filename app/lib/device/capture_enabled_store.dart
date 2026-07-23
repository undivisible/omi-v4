import 'package:shared_preferences/shared_preferences.dart';

/// Remembers whether the pendant should be capturing. Capture is on by
/// default and starts on its own whenever the pendant connects, so this only
/// records the user deliberately turning it off.
abstract interface class CaptureEnabledStore {
  Future<bool> read();
  Future<void> save(bool enabled);
}

final class PreferencesCaptureEnabledStore implements CaptureEnabledStore {
  static const _key = 'capture_enabled_v1';

  @override
  Future<bool> read() async =>
      (await SharedPreferences.getInstance()).getBool(_key) ?? true;

  @override
  Future<void> save(bool enabled) async {
    await (await SharedPreferences.getInstance()).setBool(_key, enabled);
  }
}

final class VolatileCaptureEnabledStore implements CaptureEnabledStore {
  VolatileCaptureEnabledStore({this.enabled = true});

  bool enabled;

  @override
  Future<bool> read() async => enabled;

  @override
  Future<void> save(bool value) async => enabled = value;
}
