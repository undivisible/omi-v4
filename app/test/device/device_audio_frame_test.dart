import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/device.dart';

void main() {
  test('decodes the Omi firmware audio header', () {
    final frame = DeviceAudioFrame.decode([0x34, 0x12, 0x07, 10, 11]);

    expect(frame?.packetId, 0x1234);
    expect(frame?.packetIndex, 7);
    expect(frame?.payload, [10, 11]);
  });

  test('rejects packets without audio payload', () {
    expect(DeviceAudioFrame.decode([0, 0, 0]), isNull);
  });

  test('reassembles fragmented physical Omi codec packets', () async {
    final frames = await decodeDeviceAudioFrames(
      Stream.fromIterable([
        [10, 0, 0, 1, 2],
        [11, 0, 1, 3, 4],
        [12, 0, 0, 5, 6],
      ]),
    ).toList();

    expect(frames, hasLength(2));
    expect(frames[0].packetId, 11);
    expect(frames[0].firstPacketId, 10);
    expect(frames[0].packetIndex, 0);
    expect(frames[0].payload, [1, 2, 3, 4]);
    expect(frames[1].packetId, 12);
    expect(frames[1].packetIndex, 0);
    expect(frames[1].payload, [5, 6]);
  });

  test('drops a fragmented codec packet after a physical packet gap', () async {
    final frames = await decodeDeviceAudioFrames(
      Stream.fromIterable([
        [10, 0, 0, 1],
        [12, 0, 1, 2],
        [13, 0, 0, 3],
      ]),
    ).toList();

    expect(frames, hasLength(2));
    expect(frames.first.complete, isFalse);
    expect(frames.first.payload, isEmpty);
    expect(frames.last.complete, isTrue);
    expect(frames.last.payload, [3]);
  });

  test(
    'does not emit a partial codec packet before a new-packet gap',
    () async {
      final frames = await decodeDeviceAudioFrames(
        Stream.fromIterable([
          [10, 0, 0, 1],
          [12, 0, 0, 2],
        ]),
      ).toList();

      expect(frames, hasLength(2));
      expect(frames.first.complete, isFalse);
      expect(frames.first.payload, isEmpty);
      expect(frames.last.packetId, 12);
      expect(frames.last.payload, [2]);
    },
  );

  test('bounds codec aggregation before packet completion', () async {
    final frames = await decodeDeviceAudioFrames(
      Stream.fromIterable([
        [1, 0, 0, ...List.filled(256 * 1024 + 1, 1)],
      ]),
    ).toList();

    expect(frames, hasLength(1));
    expect(frames.single.complete, isFalse);
    expect(frames.single.payload, isEmpty);
  });

  test(
    'maps Omi firmware codec identifiers without guessing unknown values',
    () {
      expect(DeviceAudioCodec.fromFirmwareId(1), DeviceAudioCodec.pcm8);
      expect(DeviceAudioCodec.fromFirmwareId(20), DeviceAudioCodec.opus);
      expect(DeviceAudioCodec.fromFirmwareId(21), DeviceAudioCodec.opusFs320);
      expect(DeviceAudioCodec.fromFirmwareId(99), DeviceAudioCodec.unknown);
    },
  );
}
