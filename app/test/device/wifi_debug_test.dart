import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/device.dart';

void main() {
  test('encodes firmware Wi-Fi credential commands', () {
    expect(wifiCredentialsCommand('home', 'password'), [
      0x01,
      4,
      104,
      111,
      109,
      101,
      8,
      112,
      97,
      115,
      115,
      119,
      111,
      114,
      100,
    ]);
    expect(wifiCredentialsCommand('home', 'password', home: true).first, 0x10);
  });

  test('rejects credentials the firmware cannot accept', () {
    expect(() => wifiCredentialsCommand('', 'password'), throwsFormatException);
    expect(
      () => wifiCredentialsCommand('home', 'short'),
      throwsFormatException,
    );
    expect(
      () => wifiCredentialsCommand('a' * 33, 'password'),
      throwsFormatException,
    );
  });

  test('encodes cloud identity for firmware uploads', () {
    expect(wifiCloudCommand('omi.test', 'dev-1', 'token'), [
      0x12,
      8,
      ...'omi.test'.codeUnits,
      5,
      ...'dev-1'.codeUnits,
      5,
      ...'token'.codeUnits,
    ]);
  });
}
