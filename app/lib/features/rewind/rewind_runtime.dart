import 'dart:async';

import 'package:flutter/foundation.dart';

import 'rewind_platform.dart';
import 'rewind_service.dart';
import 'rewind_settings_store.dart';
import 'rewind_store.dart';

/// A capture platform that never captures. Used on every platform that is not
/// macOS, and in the settings window's engine, where the controls must work
/// but a second capture loop must not exist.
final class InertRewindCapturePlatform implements RewindCapturePlatform {
  const InertRewindCapturePlatform();

  @override
  Future<RewindSystemState> readState() async => RewindSystemState.unavailable;

  @override
  Future<Uint8List?> preview() async => null;

  @override
  Future<RewindEncodedFrame?> encodeHeldFrame({
    bool recognizeText = true,
  }) async => null;

  @override
  Future<void> discardHeldFrame() async {}

  @override
  Future<void> setIndicator({
    required bool recording,
    required bool paused,
  }) async {}

  @override
  void setIndicatorHandler(void Function(String action)? handler) {}
}

bool get rewindSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Process-wide access to the Rewind service. Each Flutter engine gets one
/// instance; only the primary engine's instance captures, because only it
/// registers the native bridge.
final class RewindRuntime {
  RewindRuntime._();

  static final RewindRuntime instance = RewindRuntime._();

  RewindService? _service;
  Future<RewindService>? _pending;

  /// [captures] is true for the primary engine and false for the settings
  /// window, which shares the settings file and the frame store but must not
  /// run a capture loop.
  Future<RewindService> resolve({required bool captures}) {
    final existing = _pending;
    if (existing != null) return existing;
    return _pending = _create(captures: captures);
  }

  RewindService? get serviceOrNull => _service;

  Future<RewindService> _create({required bool captures}) async {
    final store = await RewindStore.open();
    final service = RewindService(
      platform: captures && rewindSupported
          ? MacRewindCapturePlatform()
          : const InertRewindCapturePlatform(),
      store: store,
      settingsStore: FileRewindSettingsStore(),
      captures: captures && rewindSupported,
    );
    await service.initialize();
    _service = service;
    return service;
  }
}
