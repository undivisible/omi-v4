import 'package:shared_preferences/shared_preferences.dart';

abstract interface class PairedDeviceStore {
  Future<String?> read();
  Future<void> save(String deviceId);
  Future<void> clear();
}

final class PreferencesPairedDeviceStore implements PairedDeviceStore {
  static const _key = 'paired_device_id_v1';

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(_key);

  @override
  Future<void> save(String deviceId) async {
    final saved = await (await SharedPreferences.getInstance()).setString(
      _key,
      deviceId,
    );
    if (!saved) {
      throw StateError('Could not persist the paired device.');
    }
  }

  @override
  Future<void> clear() async {
    await (await SharedPreferences.getInstance()).remove(_key);
  }
}

final class VolatilePairedDeviceStore implements PairedDeviceStore {
  String? _deviceId;

  @override
  Future<String?> read() async => _deviceId;

  @override
  Future<void> save(String deviceId) async => _deviceId = deviceId;

  @override
  Future<void> clear() async => _deviceId = null;
}
