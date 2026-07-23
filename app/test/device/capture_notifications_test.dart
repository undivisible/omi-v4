import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/capture_notifications.dart';

void main() {
  late RecordingCaptureAlertPresenter presenter;
  late VolatileCaptureAlertSettingsStore store;
  late CaptureAlerts alerts;

  Future<CaptureAlerts> build([CaptureAlertSettings? settings]) async {
    presenter = RecordingCaptureAlertPresenter();
    store = VolatileCaptureAlertSettingsStore(
      settings ?? const CaptureAlertSettings(),
    );
    alerts = CaptureAlerts(presenter: presenter, settingsStore: store);
    await alerts.load();
    addTearDown(alerts.dispose);
    return alerts;
  }

  test(
    'low battery fires once on crossing and rearms above the ceiling',
    () async {
      await build();
      await alerts.batteryLevel(80);
      await alerts.batteryLevel(15);
      await alerts.batteryLevel(12);
      await alerts.batteryLevel(9);
      expect(presenter.presented, hasLength(1));
      expect(presenter.presented.single.alert, CaptureAlert.lowBattery);

      await alerts.batteryLevel(90);
      await alerts.batteryLevel(10);
      expect(presenter.presented, hasLength(2));
    },
  );

  test('capture stopped carries the reason it was given', () async {
    await build();
    await alerts.captureStopped('Audio from your Omi was interrupted.');
    expect(presenter.presented.single.alert, CaptureAlert.captureStopped);
    expect(
      presenter.presented.single.body,
      'Audio from your Omi was interrupted.',
    );
  });

  test('nothing is presented while the alerts are disabled', () async {
    await build(
      const CaptureAlertSettings(lowBattery: false, captureStopped: false),
    );
    await alerts.batteryLevel(3);
    await alerts.captureStopped('anything');
    expect(presenter.presented, isEmpty);
  });

  test('each alert can be suppressed on its own', () async {
    await build(const CaptureAlertSettings(lowBattery: false));
    await alerts.batteryLevel(3);
    await alerts.captureStopped('stopped');
    expect(presenter.presented.map((entry) => entry.alert), [
      CaptureAlert.captureStopped,
    ]);
  });

  test('turning an alert off persists and takes effect immediately', () async {
    await build();
    await alerts.setEnabled(CaptureAlert.captureStopped, false);
    await alerts.captureStopped('stopped');
    expect(presenter.presented, isEmpty);
    expect(store.settings.captureStopped, isFalse);
    expect(store.settings.lowBattery, isTrue);

    await alerts.setEnabled(CaptureAlert.captureStopped, true);
    await alerts.captureStopped('stopped');
    expect(presenter.presented, hasLength(1));
  });
}
