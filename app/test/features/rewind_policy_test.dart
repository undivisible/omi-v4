import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/rewind/rewind_dhash.dart';
import 'package:omi/features/rewind/rewind_models.dart';
import 'package:omi/features/rewind/rewind_policy.dart';
import 'package:omi/features/rewind/rewind_privacy.dart';

const _config = RewindPolicyConfig(
  interactiveHeartbeat: Duration(seconds: 20),
  slowChangingHeartbeat: Duration(minutes: 3),
  idleAfter: Duration(minutes: 2),
  minimumInterval: Duration(seconds: 3),
);

RewindTick _tick(
  DateTime now, {
  String bundleId = 'com.apple.Terminal',
  String? title = 'zsh',
  Duration idleFor = Duration.zero,
  bool locked = false,
  bool paused = false,
  bool busy = false,
  bool permitted = true,
}) => RewindTick(
  now: now,
  context: RewindWindowContext(
    bundleId: bundleId,
    appName: bundleId,
    windowTitle: title,
  ),
  idleFor: idleFor,
  locked: locked,
  paused: paused,
  busy: busy,
  permitted: permitted,
);

RewindPreviewHash _hash(int seed) {
  final luma = Uint8List(kRewindPreviewLength);
  for (var index = 0; index < luma.length; index++) {
    luma[index] = (index * seed) % 251;
  }
  return RewindPreviewHash.fromLuma(luma)!;
}

void main() {
  final start = DateTime(2026, 7, 23, 9);

  test('the first look at a screen is always a capture', () {
    final policy = RewindCapturePolicy(config: _config);
    expect(policy.evaluate(_tick(start)).capture, isTrue);
  });

  test('a paused, locked, unpermitted or denied screen is never captured', () {
    final policy = RewindCapturePolicy(config: _config);
    expect(
      policy.evaluate(_tick(start, paused: true)).reason,
      RewindSkipReason.paused,
    );
    expect(
      policy.evaluate(_tick(start, locked: true)).reason,
      RewindSkipReason.screenLocked,
    );
    expect(
      policy.evaluate(_tick(start, permitted: false)).reason,
      RewindSkipReason.noPermission,
    );
    expect(
      policy.evaluate(_tick(start, bundleId: 'com.1password.1password')).reason,
      RewindSkipReason.deniedApp,
    );
    expect(
      policy.evaluate(_tick(start, title: 'Search — Private Browsing')).reason,
      RewindSkipReason.privateWindow,
    );
  });

  test('pause outranks every other reason', () {
    final policy = RewindCapturePolicy(config: _config);
    final decision = policy.evaluate(
      _tick(
        start,
        paused: true,
        locked: true,
        bundleId: 'com.1password.1password',
      ),
    );
    expect(decision.reason, RewindSkipReason.paused);
  });

  test('backpressure drops the tick rather than queueing it', () {
    final policy = RewindCapturePolicy(config: _config);
    expect(
      policy.evaluate(_tick(start, busy: true)).reason,
      RewindSkipReason.busy,
    );
  });

  test('a window title change captures without waiting for the heartbeat', () {
    final policy = RewindCapturePolicy(config: _config);
    policy.recordCapture(_tick(start), _hash(3));
    expect(
      policy.evaluate(_tick(start.add(const Duration(seconds: 4)))).reason,
      RewindSkipReason.heartbeat,
    );
    final switched = _tick(
      start.add(const Duration(seconds: 4)),
      title: 'vim main.dart',
    );
    expect(policy.evaluate(switched).capture, isTrue);
  });

  test('the minimum interval floors a burst of context changes', () {
    final policy = RewindCapturePolicy(config: _config);
    policy.recordCapture(_tick(start), _hash(3));
    final rapid = _tick(
      start.add(const Duration(seconds: 1)),
      bundleId: 'com.apple.Safari',
    );
    expect(policy.evaluate(rapid).reason, RewindSkipReason.minimumInterval);
  });

  test(
    'a slow-changing app captures far less often than an interactive one',
    () {
      final policy = RewindCapturePolicy(config: _config);
      const music = 'com.apple.Music';
      expect(
        policy.tempoFor(const RewindWindowContext(bundleId: music)),
        RewindAppTempo.slowChanging,
      );
      policy.recordCapture(
        _tick(start, bundleId: music, title: 'Album'),
        _hash(3),
      );
      expect(
        policy
            .evaluate(
              _tick(
                start.add(const Duration(seconds: 45)),
                bundleId: music,
                title: 'Album',
              ),
            )
            .reason,
        RewindSkipReason.heartbeat,
      );
      expect(
        policy
            .evaluate(
              _tick(
                start.add(const Duration(minutes: 4)),
                bundleId: music,
                title: 'Album',
              ),
            )
            .capture,
        isTrue,
      );

      final interactive = RewindCapturePolicy(config: _config);
      interactive.recordCapture(_tick(start), _hash(3));
      expect(
        interactive
            .evaluate(_tick(start.add(const Duration(seconds: 45))))
            .capture,
        isTrue,
      );
    },
  );

  test('the heartbeat stops entirely once the user is idle', () {
    final policy = RewindCapturePolicy(config: _config);
    policy.recordCapture(_tick(start), _hash(3));
    expect(
      policy
          .evaluate(
            _tick(
              start.add(const Duration(minutes: 10)),
              idleFor: const Duration(minutes: 5),
            ),
          )
          .reason,
      RewindSkipReason.idle,
    );
  });

  test('an unchanged preview is skipped, a changed one is kept', () {
    final policy = RewindCapturePolicy(config: _config);
    final first = _hash(3);
    policy.recordCapture(_tick(start), first);
    final later = _tick(start.add(const Duration(seconds: 30)));
    expect(
      policy.evaluatePreview(later, first).reason,
      RewindSkipReason.unchanged,
    );
    expect(policy.evaluatePreview(later, _hash(29)).capture, isTrue);
  });

  test('a new window always beats the similarity gate', () {
    final policy = RewindCapturePolicy(config: _config);
    final hash = _hash(3);
    policy.recordCapture(_tick(start), hash);
    final elsewhere = _tick(
      start.add(const Duration(seconds: 30)),
      bundleId: 'com.apple.Safari',
      title: 'Docs',
    );
    expect(policy.evaluatePreview(elsewhere, hash).capture, isTrue);
  });

  test('reset makes the next tick capture immediately', () {
    final policy = RewindCapturePolicy(config: _config);
    policy.recordCapture(_tick(start), _hash(3));
    policy.reset();
    expect(
      policy.evaluate(_tick(start.add(const Duration(seconds: 1)))).capture,
      isTrue,
    );
  });
}
