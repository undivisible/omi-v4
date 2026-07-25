import 'dart:convert';
import 'dart:typed_data';

const wifiSuccess = 0x00;
const wifiHardwareUnavailable = 0xfe;

Uint8List wifiCredentialsCommand(
  String ssid,
  String password, {
  bool home = false,
}) {
  final ssidBytes = utf8.encode(ssid);
  final passwordBytes = utf8.encode(password);
  if (ssidBytes.isEmpty || ssidBytes.length > 32) {
    throw const FormatException('Wi-Fi name must be 1–32 bytes');
  }
  if (passwordBytes.length < 8 || passwordBytes.length > 64) {
    throw const FormatException('Wi-Fi password must be 8–64 bytes');
  }
  return Uint8List.fromList([
    home ? 0x10 : 0x01,
    ssidBytes.length,
    ...ssidBytes,
    passwordBytes.length,
    ...passwordBytes,
  ]);
}

String wifiResultMessage(int code) => switch (code) {
  0x00 => 'Command accepted',
  0x01 => 'Invalid command length',
  0x02 => 'Invalid Wi-Fi setup',
  0x03 => 'Invalid Wi-Fi name',
  0x04 => 'Password must be 8–64 bytes',
  0x05 => 'Wi-Fi sync is already running',
  0x10 => 'Could not clear device recordings',
  0x20 => 'Home Wi-Fi syncing is unavailable in this firmware',
  0x21 => 'Cloud sync token is invalid',
  0xfe => 'Wi-Fi hardware is unavailable',
  _ =>
    'Firmware rejected the command (0x${code.toRadixString(16).padLeft(2, '0')})',
};
