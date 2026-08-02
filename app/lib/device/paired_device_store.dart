import 'package:shared_preferences/shared_preferences.dart';

/// Remembers every pendant the owner has paired, plus which one is active.
/// Owning several pendants is the normal case, so [readAll] is what the device
/// list renders and [read] is only the one auto-reconnect should try.
abstract interface class PairedDeviceStore {
  Future<String?> read();

  /// Remembers [deviceId] and makes it the active pendant. Re-saving a device
  /// already in the list must not duplicate it, because the list renders one
  /// row per entry.
  Future<void> save(String deviceId);

  /// Forgets the active pendant only. The other remembered pendants survive,
  /// so resetting one does not un-pair the rest.
  Future<void> clear();

  Future<List<String>> readAll();

  Future<void> forget(String deviceId);
}

final class PreferencesPairedDeviceStore implements PairedDeviceStore {
  static const _key = 'paired_device_id_v1';
  static const _listKey = 'paired_device_ids_v1';

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(_key);

  /// Layered on top of the single-device key rather than replacing it: an
  /// install that paired before multi-device support has only [_key] set, and
  /// ignoring it would silently un-pair the owner's pendant on upgrade.
  @override
  Future<List<String>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_listKey);
    final active = prefs.getString(_key);
    final ids = <String>[...?stored];
    if (active != null && !ids.contains(active)) ids.insert(0, active);
    return ids;
  }

  @override
  Future<void> save(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = await readAll();
    if (!ids.contains(deviceId)) ids.add(deviceId);
    final listed = await prefs.setStringList(_listKey, ids);
    final saved = await prefs.setString(_key, deviceId);
    if (!saved || !listed) {
      throw StateError('Could not persist the paired device.');
    }
  }

  @override
  Future<void> clear() async {
    final active = await read();
    if (active == null) {
      await (await SharedPreferences.getInstance()).remove(_key);
      return;
    }
    await forget(active);
  }

  @override
  Future<void> forget(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (await readAll())..remove(deviceId);
    await prefs.setStringList(_listKey, ids);
    if (prefs.getString(_key) == deviceId) {
      await prefs.remove(_key);
    }
  }
}

final class VolatilePairedDeviceStore implements PairedDeviceStore {
  final List<String> _deviceIds = [];
  String? _deviceId;

  @override
  Future<String?> read() async => _deviceId;

  @override
  Future<List<String>> readAll() async => List.of(_deviceIds);

  @override
  Future<void> save(String deviceId) async {
    if (!_deviceIds.contains(deviceId)) _deviceIds.add(deviceId);
    _deviceId = deviceId;
  }

  @override
  Future<void> clear() async {
    final active = _deviceId;
    if (active != null) await forget(active);
  }

  @override
  Future<void> forget(String deviceId) async {
    _deviceIds.remove(deviceId);
    if (_deviceId == deviceId) _deviceId = null;
  }
}
