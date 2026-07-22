import 'package:flutter_test/flutter_test.dart';
import 'package:omi/native/native_hub.dart' show SystemAudioCaptureMode;
import 'package:omi/settings/system_audio_capture_mode_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('capture mode round-trips through shared preferences', () async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferencesSystemAudioCaptureModeStore();
    expect(await store.read(), SystemAudioCaptureMode.onlyDuringMeetings);
    await store.write(SystemAudioCaptureMode.never);
    expect(await store.read(), SystemAudioCaptureMode.never);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'systemAudioCaptureMode',
      ),
      'never',
    );
    await store.write(SystemAudioCaptureMode.always);
    expect(await store.read(), SystemAudioCaptureMode.always);
  });

  test('unknown persisted values fall back to the default mode', () {
    expect(
      systemAudioCaptureModeFromName('garbage'),
      SystemAudioCaptureMode.onlyDuringMeetings,
    );
    expect(
      systemAudioCaptureModeFromName(null),
      SystemAudioCaptureMode.onlyDuringMeetings,
    );
    for (final mode in SystemAudioCaptureMode.values) {
      expect(
        systemAudioCaptureModeFromName(systemAudioCaptureModeName(mode)),
        mode,
      );
    }
  });
}
