import 'package:shared_preferences/shared_preferences.dart';

import '../native/native_hub.dart' show SystemAudioCaptureMode;

abstract interface class SystemAudioCaptureModeStore {
  Future<SystemAudioCaptureMode> read();
  Future<void> write(SystemAudioCaptureMode mode);
}

String systemAudioCaptureModeName(SystemAudioCaptureMode mode) =>
    switch (mode) {
      SystemAudioCaptureMode.always => 'always',
      SystemAudioCaptureMode.onlyDuringMeetings => 'onlyDuringMeetings',
      SystemAudioCaptureMode.never => 'never',
    };

SystemAudioCaptureMode systemAudioCaptureModeFromName(String? name) =>
    switch (name) {
      'always' => SystemAudioCaptureMode.always,
      'never' => SystemAudioCaptureMode.never,
      _ => SystemAudioCaptureMode.onlyDuringMeetings,
    };

final class PreferencesSystemAudioCaptureModeStore
    implements SystemAudioCaptureModeStore {
  static const _key = 'systemAudioCaptureMode';

  @override
  Future<SystemAudioCaptureMode> read() async => systemAudioCaptureModeFromName(
    (await SharedPreferences.getInstance()).getString(_key),
  );

  @override
  Future<void> write(SystemAudioCaptureMode mode) async {
    final saved = await (await SharedPreferences.getInstance()).setString(
      _key,
      systemAudioCaptureModeName(mode),
    );
    if (!saved) {
      throw StateError('Could not save the system audio capture mode.');
    }
  }
}

final class VolatileSystemAudioCaptureModeStore
    implements SystemAudioCaptureModeStore {
  SystemAudioCaptureMode value = SystemAudioCaptureMode.onlyDuringMeetings;

  @override
  Future<SystemAudioCaptureMode> read() async => value;

  @override
  Future<void> write(SystemAudioCaptureMode mode) async => value = mode;
}
