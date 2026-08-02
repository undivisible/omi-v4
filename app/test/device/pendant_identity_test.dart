import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/device_identity.dart';
import 'package:omi/device/paired_device_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PendantIdentity', () {
    test('gives the same pendant the same colour every time', () {
      final first = PendantIdentity.forDeviceId('AA:BB:CC:DD:EE:01');
      final second = PendantIdentity.forDeviceId('AA:BB:CC:DD:EE:01');
      expect(second, first);
    });

    test('does not depend on how the platform cases the device id', () {
      expect(
        PendantIdentity.forDeviceId('aa:bb:cc:dd:ee:01'),
        PendantIdentity.forDeviceId('AA:BB:CC:DD:EE:01'),
      );
    });

    test('separates the pendants an owner is likely to hold at once', () {
      final identities = {
        for (final id in ['omi-1', 'omi-2', 'omi-3'])
          PendantIdentity.forDeviceId(id),
      };
      expect(identities.length, 3);
    });

    test('stays inside what the three-channel LED can show', () {
      expect(PendantIdentity.values.length, 6);
      for (final identity in PendantIdentity.values) {
        expect(PendantIdentity.fromCode(identity.code), identity);
      }
      expect(PendantIdentity.fromCode(6), isNull);
    });
  });

  group('PairedDeviceStore', () {
    test('remembers several pendants and tracks the active one', () async {
      final store = VolatilePairedDeviceStore();
      await store.save('omi-1');
      await store.save('omi-2');
      await store.save('omi-3');

      expect(await store.readAll(), ['omi-1', 'omi-2', 'omi-3']);
      expect(await store.read(), 'omi-3');
    });

    test('re-selecting a remembered pendant does not duplicate its row', () async {
      final store = VolatilePairedDeviceStore();
      await store.save('omi-1');
      await store.save('omi-2');
      await store.save('omi-1');

      expect(await store.readAll(), ['omi-1', 'omi-2']);
      expect(await store.read(), 'omi-1');
    });

    test('forgetting one pendant leaves the others paired', () async {
      final store = VolatilePairedDeviceStore();
      await store.save('omi-1');
      await store.save('omi-2');

      await store.forget('omi-2');

      expect(await store.readAll(), ['omi-1']);
      expect(await store.read(), isNull);
    });

    test('clear forgets only the active pendant', () async {
      final store = VolatilePairedDeviceStore();
      await store.save('omi-1');
      await store.save('omi-2');

      await store.clear();

      expect(await store.readAll(), ['omi-1']);
    });
  });

  group('PreferencesPairedDeviceStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('carries a pre-multi-device pairing forward', () async {
      // What an install that paired before the device list looks like: only
      // the single-device key is set, and dropping it would silently un-pair
      // the owner's pendant on upgrade.
      SharedPreferences.setMockInitialValues({
        'paired_device_id_v1': 'omi-legacy',
      });
      final store = PreferencesPairedDeviceStore();

      expect(await store.readAll(), ['omi-legacy']);
      expect(await store.read(), 'omi-legacy');

      await store.save('omi-2');
      expect(await store.readAll(), ['omi-legacy', 'omi-2']);
      expect(await store.read(), 'omi-2');
    });

    test('persists the list and the active pendant separately', () async {
      final store = PreferencesPairedDeviceStore();
      await store.save('omi-1');
      await store.save('omi-2');
      await store.forget('omi-2');

      expect(await store.readAll(), ['omi-1']);
      expect(await store.read(), isNull);

      await store.save('omi-1');
      expect(await store.read(), 'omi-1');
      expect(await store.readAll(), ['omi-1']);
    });
  });
}
