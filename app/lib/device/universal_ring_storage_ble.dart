import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'ring_backlog.dart';

final class UniversalRingStorageBle implements RingStorageBle {
  UniversalRingStorageBle(this.deviceId);

  static const service = '30295780-4301-eabd-2904-2849adfeae43';
  static const control = '30295781-4301-eabd-2904-2849adfeae43';

  final String deviceId;
  var _subscribed = false;

  @override
  Stream<List<int>> get storageNotifications =>
      UniversalBle.characteristicValueStream(deviceId, control);

  @override
  Future<void> writeStorage(Uint8List bytes) async {
    if (!_subscribed) {
      await UniversalBle.subscribeNotifications(deviceId, service, control);
      _subscribed = true;
    }
    await UniversalBle.write(deviceId, service, control, bytes);
  }
}
