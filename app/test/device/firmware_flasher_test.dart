import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcumgr_flutter/mcumgr_flutter.dart' as mcumgr;
import 'package:mcumgr_flutter/models/firmware_upgrade_mode.dart'
    show FirmwareUpgradeMode;
import 'package:omi/device/firmware_dfu.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  final images = [
    FirmwareImage(
      image: 0,
      file: 'app_update.bin',
      data: Uint8List.fromList([1, 2, 3, 4]),
    ),
    FirmwareImage(
      image: 1,
      file: 'net_core_app_update.bin',
      data: Uint8List.fromList([9, 9]),
    ),
  ];

  late _FakeUpdateManager manager;
  late List<FirmwareFlashProgress> seen;
  late List<Object> errors;
  late bool done;

  setUp(() {
    manager = _FakeUpdateManager();
    seen = [];
    errors = [];
    done = false;
  });

  Future<StreamSubscription<FirmwareFlashProgress>> start({
    mcumgr.UpdateManagerFactory? factory,
  }) async {
    final subscription =
        McuMgrFirmwareFlasher(factory: factory ?? _FakeFactory(manager))
            .flash(deviceId: 'omi-1', images: images)
            .listen(seen.add, onError: errors.add, onDone: () => done = true);
    await pump();
    await pump();
    return subscription;
  }

  test('the swap is never test-then-confirm and never erases settings', () {
    expect(
      McuMgrFirmwareFlasher.configuration.eraseAppSettings,
      isFalse,
      reason: 'erasing NVS would reset the pendant name and mic gain',
    );
    expect(
      McuMgrFirmwareFlasher.configuration.firmwareUpgradeMode,
      FirmwareUpgradeMode.confirmOnly,
    );
  });

  test('both cores are handed to mcumgr in one upload', () async {
    await start();

    expect(manager.deviceId, 'omi-1');
    expect(manager.uploaded?.map((image) => image.image), [0, 1]);
    expect(manager.uploaded?.first.data, [1, 2, 3, 4]);
    expect(manager.configuration?.eraseAppSettings, isFalse);
    expect(seen.single.stage, FirmwareFlashStage.preparing);
    expect(seen.single.progress, isNull);
    expect(done, isFalse);
  });

  test(
    'device states are reported as the stage the user cares about',
    () async {
      await start();
      for (final state in const [
        mcumgr.FirmwareUpgradeState.validate,
        mcumgr.FirmwareUpgradeState.upload,
        mcumgr.FirmwareUpgradeState.test,
        mcumgr.FirmwareUpgradeState.reset,
        mcumgr.FirmwareUpgradeState.confirm,
      ]) {
        manager.states.add(state);
      }
      await pump();

      expect(seen.map((event) => event.stage), [
        FirmwareFlashStage.preparing,
        FirmwareFlashStage.preparing,
        FirmwareFlashStage.uploading,
        FirmwareFlashStage.swapping,
        FirmwareFlashStage.swapping,
        FirmwareFlashStage.swapping,
      ]);
      expect(done, isFalse);
    },
  );

  test('a success closes the flash without an error', () async {
    await start();
    manager.states.add(mcumgr.FirmwareUpgradeState.success);
    await pump();

    expect(seen.map((event) => event.stage), [FirmwareFlashStage.preparing]);
    expect(errors, isEmpty);
    expect(done, isTrue);
  });

  test('upload fractions are reported and clamped', () async {
    await start();
    manager.progress
      ..add(mcumgr.ProgressUpdate(0, 0, DateTime.utc(2026)))
      ..add(mcumgr.ProgressUpdate(1, 4, DateTime.utc(2026)))
      ..add(mcumgr.ProgressUpdate(9, 4, DateTime.utc(2026)));
    await pump();

    expect(seen.map((event) => event.progress), [null, 0.25, 1.0]);
    expect(
      seen.skip(1).map((event) => event.stage),
      everyElement(FirmwareFlashStage.uploading),
    );
  });

  test('a failing state stream surfaces the error and stops', () async {
    await start();
    manager.states
      ..add(mcumgr.FirmwareUpgradeState.upload)
      ..addError(StateError('link lost'));
    await pump();
    manager.progress.add(mcumgr.ProgressUpdate(1, 4, DateTime.utc(2026)));
    await pump();

    expect(errors.single, isStateError);
    expect(done, isTrue);
    expect(seen.map((event) => event.stage), [
      FirmwareFlashStage.preparing,
      FirmwareFlashStage.uploading,
    ]);
  });

  test('the state stream closing ends the flash quietly', () async {
    await start();
    await manager.states.close();
    await pump();

    expect(errors, isEmpty);
    expect(done, isTrue);
  });

  test('a progress stream failure does not abort a healthy flash', () async {
    await start();
    manager.progress
      ..add(mcumgr.ProgressUpdate(1, 4, DateTime.utc(2026)))
      ..addError(StateError('notification dropped'));
    await pump();
    manager.states.add(mcumgr.FirmwareUpgradeState.confirm);
    await pump();

    expect(errors, isEmpty);
    expect(done, isFalse);
    expect(seen.last.stage, FirmwareFlashStage.swapping);
  });

  test('a pendant that never answers the factory fails the flash', () async {
    await start(
      factory: _FakeFactory(null, failure: StateError('not connected')),
    );

    expect(seen.single.stage, FirmwareFlashStage.preparing);
    expect(errors.single, isStateError);
    expect(done, isTrue);
  });

  test('an upload that is refused fails the flash', () async {
    manager.updateFailure = StateError('no slot');

    await start();

    expect(errors.single, isStateError);
    expect(done, isTrue);
  });

  test('cancelling the flash kills the manager and its streams', () async {
    final subscription = await start();

    await subscription.cancel();

    expect(manager.killed, 1);
    expect(manager.states.hasListener, isFalse);
    expect(manager.progress.hasListener, isFalse);
  });

  test('a manager that cannot be killed does not break teardown', () async {
    manager.killFailure = StateError('already gone');
    final subscription = await start();

    await subscription.cancel();

    expect(manager.killed, 1);
  });

  test('the flash reports itself for diagnostics', () {
    expect(
      images.first.toString(),
      'FirmwareImage(0, app_update.bin, 4 bytes)',
    );
    expect(
      const FirmwareFlashProgress(FirmwareFlashStage.uploading, 0.5).toString(),
      'FirmwareFlashProgress(FirmwareFlashStage.uploading, 0.5)',
    );
  });
}

final class _FakeFactory implements mcumgr.UpdateManagerFactory {
  _FakeFactory(this._manager, {this.failure});

  final _FakeUpdateManager? _manager;
  final Object? failure;

  @override
  Future<mcumgr.FirmwareUpdateManager> getUpdateManager(String deviceId) async {
    if (failure != null) throw failure!;
    return _manager!..deviceId = deviceId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeUpdateManager implements mcumgr.FirmwareUpdateManager {
  final states = StreamController<mcumgr.FirmwareUpgradeState>();
  final progress = StreamController<mcumgr.ProgressUpdate>();

  Object? updateFailure;
  Object? killFailure;
  String? deviceId;
  List<mcumgr.Image>? uploaded;
  mcumgr.FirmwareUpgradeConfiguration? configuration;
  int killed = 0;

  @override
  Stream<mcumgr.FirmwareUpgradeState> setup() => states.stream;

  @override
  Stream<mcumgr.ProgressUpdate> get progressStream => progress.stream;

  @override
  Future<void> update(
    List<mcumgr.Image> images, {
    mcumgr.FirmwareUpgradeConfiguration configuration =
        const mcumgr.FirmwareUpgradeConfiguration(),
  }) async {
    if (updateFailure != null) throw updateFailure!;
    uploaded = images;
    this.configuration = configuration;
  }

  @override
  Future<void> kill() async {
    killed += 1;
    if (killFailure != null) throw killFailure!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
