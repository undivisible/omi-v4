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
