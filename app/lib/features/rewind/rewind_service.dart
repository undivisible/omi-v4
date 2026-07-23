import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'rewind_dhash.dart';
import 'rewind_models.dart';
import 'rewind_platform.dart';
import 'rewind_policy.dart';
import 'rewind_privacy.dart';
import 'rewind_settings_store.dart';
import 'rewind_store.dart';

/// Runs the capture policy against the platform and the disk store, and
/// publishes just enough state for the UI to tell the truth about whether the
/// screen is being recorded right now.
final class RewindService extends ChangeNotifier {
  RewindService({
    required this.platform,
    required this.store,
    required this.settingsStore,
    RewindPolicyConfig config = const RewindPolicyConfig(),
    this.tickInterval = const Duration(seconds: 3),
    this.clock = DateTime.now,
    this.captures = true,
  }) : _policy = RewindCapturePolicy(config: config);

  final RewindCapturePlatform platform;
  final RewindStore store;
  final RewindSettingsStore settingsStore;
  final Duration tickInterval;
  final DateTime Function() clock;

  /// False in the settings window's engine, which shares the settings file but
  /// must never open a second capture loop of its own.
  final bool captures;

  final RewindCapturePolicy _policy;

  Timer? _timer;
  bool _inFlight = false;
  bool _disposed = false;

  RewindSettings _settings = const RewindSettings();
  RewindSkipReason? _lastSkipReason;
  DateTime? _lastCaptureAt;
  RewindSystemState _lastState = RewindSystemState.unavailable;
  int _capturedThisSession = 0;

  RewindSettings get settings => _settings;

  /// True only when a frame could actually be taken right now: enabled, not
  /// paused, permission granted, screen unlocked.
  bool get recording =>
      _settings.recording && _lastState.permitted && !_lastState.locked;

  RewindSkipReason? get lastSkipReason => _lastSkipReason;
  DateTime? get lastCaptureAt => _lastCaptureAt;
  RewindSystemState get systemState => _lastState;
  int get capturedThisSession => _capturedThisSession;
  List<RewindFrame> get frames => store.frames;
  int get totalBytes => store.totalBytes;

  Future<void> initialize() async {
    _settings = await settingsStore.read();
    _policy.privacy = _settings.privacy;
    await store.load();
    platform.setIndicatorHandler(_indicatorAction);
    await _syncIndicator();
    _startTimer();
    _notify();
  }

  /// Picks up a change made by the other engine (the settings window and the
  /// capture loop are separate isolates sharing one settings file).
  Future<void> refreshSettings() async {
    final next = await settingsStore.read();
    if (jsonEncode(next.toJson()) == jsonEncode(_settings.toJson())) return;
    final wasRecording = _settings.recording;
    _settings = next;
    _policy.privacy = next.privacy;
    if (wasRecording != next.recording) _policy.reset();
    await _syncIndicator();
    _notify();
  }

  void _indicatorAction(String action) {
    switch (action) {
      case 'pause':
        unawaited(setPaused(true));
      case 'resume':
        unawaited(setPaused(false));
      case 'disable':
        unawaited(setEnabled(false));
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (_settings.enabled == enabled) return;
    await _persist(_settings.copyWith(enabled: enabled, paused: false));
    _policy.reset();
    if (!enabled) await platform.discardHeldFrame();
  }

  Future<void> setPaused(bool paused) async {
    if (_settings.paused == paused) return;
    await _persist(_settings.copyWith(paused: paused));
    _policy.reset();
    if (paused) await platform.discardHeldFrame();
  }

  Future<void> setRetention(RewindRetention retention) async {
    await _persist(_settings.copyWith(retention: retention));
    await store.enforce(retention, now: clock());
    _notify();
  }

  Future<void> setPrivacy(RewindPrivacySettings privacy) async {
    await _persist(_settings.copyWith(privacy: privacy));
    _policy.privacy = privacy;
  }

  Future<void> denyBundleId(String bundleId) async {
    final trimmed = bundleId.trim();
    if (trimmed.isEmpty) return;
    await setPrivacy(
      _settings.privacy.copyWith(
        deniedBundleIds: {..._settings.privacy.deniedBundleIds, trimmed},
      ),
    );
  }

  Future<void> allowBundleId(String bundleId) async {
    final next = {..._settings.privacy.deniedBundleIds}..remove(bundleId);
    await setPrivacy(_settings.privacy.copyWith(deniedBundleIds: next));
  }

  /// Local, on-device search over the recognized text.
  List<RewindFrame> search(String query) => store.search(query);

  Future<void> deleteAll() async {
    await store.deleteAll();
    _policy.reset();
    _notify();
  }

  Future<int> deleteLast(Duration window) async {
    final now = clock();
    final removed = await store.deleteRange(now.subtract(window), now);
    _policy.reset();
    _notify();
    return removed;
  }

  Future<void> delete(RewindFrame frame) async {
    await store.delete(frame);
    _notify();
  }

  Future<void> _persist(RewindSettings next) async {
    _settings = next;
    await settingsStore.write(next);
    await _syncIndicator();
    _notify();
  }

  Future<void> _syncIndicator() => platform.setIndicator(
    recording: _settings.enabled,
    paused: _settings.paused,
  );

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      tickInterval,
      (_) => unawaited(captures ? pump() : refreshSettings()),
    );
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// One evaluation of the policy. Public so the schedule can be driven
  /// deterministically in tests instead of by wall-clock timers.
  Future<void> pump() async {
    if (_disposed) return;
    // Backpressure: the previous frame has not finished encoding or writing,
    // so this one is dropped rather than queued behind it.
    if (_inFlight) {
      _lastSkipReason = RewindSkipReason.busy;
      _notify();
      return;
    }
    _inFlight = true;
    try {
      await _tick();
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _tick() async {
    await refreshSettings();
    final state = await platform.readState();
    _lastState = state;
    final tick = RewindTick(
      now: clock(),
      context: state.context,
      idleFor: state.idleFor,
      locked: state.locked,
      paused: _settings.paused || !_settings.enabled,
      permitted: state.permitted,
    );

    final decision = _policy.evaluate(tick);
    if (!decision.capture) {
      _lastSkipReason = decision.reason;
      _notify();
      return;
    }

    final luma = await platform.preview();
    final hash = luma == null ? null : RewindPreviewHash.fromLuma(luma);
    if (hash == null) {
      _lastSkipReason = RewindSkipReason.noPermission;
      await platform.discardHeldFrame();
      _notify();
      return;
    }

    final previewDecision = _policy.evaluatePreview(tick, hash);
    if (!previewDecision.capture) {
      _policy.recordSkippedPreview(tick, hash);
      _lastSkipReason = previewDecision.reason;
      // The full frame is still sitting in native memory, unencoded. Drop it.
      await platform.discardHeldFrame();
      _notify();
      return;
    }

    final encoded = await platform.encodeHeldFrame(
      recognizeText: _settings.privacy.readOnScreenText,
    );
    if (encoded == null) {
      _lastSkipReason = RewindSkipReason.noPermission;
      _notify();
      return;
    }

    final title = _settings.privacy.recordWindowTitles
        ? tick.context.windowTitle
        : null;
    await store.write(
      jpeg: encoded.jpeg,
      capturedAt: tick.now,
      hash: hash.toHex(),
      retention: _settings.retention,
      appName: tick.context.appName,
      bundleId: tick.context.bundleId,
      windowTitle: title,
      ocrText: encoded.ocrText,
    );
    _policy.recordCapture(tick, hash);
    _lastCaptureAt = tick.now;
    _lastSkipReason = null;
    _capturedThisSession++;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimer();
    platform.setIndicatorHandler(null);
    super.dispose();
  }
}
