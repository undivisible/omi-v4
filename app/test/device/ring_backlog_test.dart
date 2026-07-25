import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/ring_backlog.dart';

void main() {
  test('advance follows durable import', () async {
    final ble = _Ble();
    final calls = <String>[];
    final sink = _Sink(() async => calls.add('import'));
    final client = RingBacklogClient(
      deviceId: 'omi-1',
      ble: ble,
      sink: sink,
      recordsPerRange: 1,
    );

    final imported = client.importRange(7, 1);
    await Future<void>.delayed(Duration.zero);
    ble.sendRange(7, _record());

    expect(await imported, 8);
    expect(calls, ['import']);
    expect(ble.writes.map((value) => value.first), [0x11, 0x12]);
  });

  test('corrupt range is retained on the pendant', () async {
    final ble = _Ble();
    final client = RingBacklogClient(
      deviceId: 'omi-1',
      ble: ble,
      sink: _Sink(() async {}),
      recordsPerRange: 1,
    );

    final imported = client.importRange(9, 1);
    await Future<void>.delayed(Duration.zero);
    ble.sendRange(9, _record(), crc: 1);

    await expectLater(imported, throwsFormatException);
    expect(ble.writes.map((value) => value.first), [0x11]);
  });
}

Uint8List _record() {
  final record = Uint8List(444);
  ByteData.sublistView(record).setUint32(0, 1700000000, Endian.big);
  record[4] = 2;
  record[5] = 1;
  record[6] = 2;
  return record;
}

final class _Sink implements DurableRingSink {
  const _Sink(this.callback);

  final Future<void> Function() callback;

  @override
  Future<void> importRange(DurableRingRange range) => callback();
}

final class _Ble implements RingStorageBle {
  final controller = StreamController<List<int>>.broadcast();
  final writes = <Uint8List>[];

  @override
  Stream<List<int>> get storageNotifications => controller.stream;

  @override
  Future<void> writeStorage(Uint8List bytes) async {
    writes.add(bytes);
    if (bytes.first == 0x12) scheduleMicrotask(() => controller.add([1, 0]));
  }

  void sendRange(int start, Uint8List record, {int? crc}) {
    controller.add(
      (ByteData(13)
            ..setUint8(0, 0x05)
            ..setUint64(1, start, Endian.big)
            ..setUint32(9, 1, Endian.big))
          .buffer
          .asUint8List(),
    );
    controller.add([0x03, ...record]);
    controller.add(
      (ByteData(14)
            ..setUint8(0, 0x04)
            ..setUint8(1, 0)
            ..setUint64(2, start + 1, Endian.big)
            ..setUint32(10, crc ?? _crc32(record), Endian.big))
          .buffer
          .asUint8List(),
    );
  }
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
