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

Uint8List wifiCloudCommand(String host, String deviceId, String token) {
  final hostBytes = utf8.encode(host);
  final deviceIdBytes = utf8.encode(deviceId);
  final tokenBytes = utf8.encode(token);
  if (hostBytes.isEmpty || hostBytes.length > 128) {
    throw const FormatException('Cloud host must be 1–128 bytes');
  }
  if (deviceIdBytes.isEmpty || deviceIdBytes.length > 64) {
    throw const FormatException('Device ID must be 1–64 bytes');
  }
  if (tokenBytes.isEmpty || tokenBytes.length > 96) {
    throw const FormatException('Device token must be 1–96 bytes');
  }
  return Uint8List.fromList([
    0x12,
    hostBytes.length,
    ...hostBytes,
    deviceIdBytes.length,
    ...deviceIdBytes,
    tokenBytes.length,
    ...tokenBytes,
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
