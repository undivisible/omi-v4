import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cursor_pill_window.dart';

const _keyboardControl = MethodChannel('omi/desktop_keyboard_control');

Future<void> openHubWindow() async {
  await CursorPillWindow.restore();
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;
  try {
    await _keyboardControl.invokeMethod('focus');
  } on MissingPluginException {
    return;
  } on PlatformException {
    return;
  }
}
