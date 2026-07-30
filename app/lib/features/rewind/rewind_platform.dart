import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../native/native_hub.dart';

/// True on the one platform that has both a framebuffer worth remembering and
/// the native capture surface this file talks to. Everywhere else the engine
/// exists but never captures.
bool get rewindSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Reads a window context off the channel. The trimming matters: a blank field
/// is the absence of a fact, not the empty string, and the hub's heartbeat
/// treats a changed context as a reason to capture.
RewindWindowContext rewindContextFromMap(Object? value) {
  if (value is! Map) return const RewindWindowContext();
  String? field(String key) {
    final raw = value[key];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  return RewindWindowContext(
    bundleId: field('bundleId'),
    appName: field('appName'),
    windowTitle: field('windowTitle'),
  );
}

/// One sample of the machine's state, taken before any pixels are read.
final class RewindSystemState {
  const RewindSystemState({
    required this.context,
    required this.idleFor,
    required this.locked,
    required this.permitted,
  });

  final RewindWindowContext context;
  final Duration idleFor;
  final bool locked;
  final bool permitted;

  static const unavailable = RewindSystemState(
    context: RewindWindowContext(),
    idleFor: Duration.zero,
    locked: true,
    permitted: false,
  );
}

/// The encoded result of one held frame: the JPEG bytes, plus whatever Apple's
/// Vision framework read off it on-device. The text is the primary artefact —
/// it is what search and any downstream model consumes — and it is produced
/// without a network call.
final class RewindEncodedFrame {
  const RewindEncodedFrame({required this.jpeg, this.ocrText});

  final Uint8List jpeg;
  final String? ocrText;

  static RewindEncodedFrame? fromMap(Object? value) {
    if (value is! Map) return null;
    final jpeg = value['jpeg'];
    if (jpeg is! Uint8List || jpeg.isEmpty) return null;
    final text = value['text'];
    final trimmed = text is String ? text.trim() : '';
    return RewindEncodedFrame(
      jpeg: jpeg,
      ocrText: trimmed.isEmpty ? null : trimmed,
    );
  }
}

/// The capture surface the policy drives. Split in two on purpose: [preview]
/// grabs the screen and hands back only a tiny luminance thumbnail, holding
/// the frame natively; [encodeHeldFrame] turns that same held frame into JPEG
/// bytes and is only ever called once the policy has decided to keep it. No
/// frame is ever encoded and then thrown away, and no encoded frame is ever
/// decoded again.
abstract interface class RewindCapturePlatform {
  Future<RewindSystemState> readState();

  Future<List<RewindDisplay>> displays();

  /// Captures the screen and returns the 72-byte luminance preview, keeping
  /// the full frame in native memory. Null when nothing could be captured.
  Future<Uint8List?> preview(RewindDisplay display);

  /// Encodes the frame held by the last [preview] call, and — when
  /// [recognizeText] is set — runs on-device text recognition over it in the
  /// same pass. Null when the held frame is gone (a newer preview replaced it,
  /// or capture failed).
  Future<RewindEncodedFrame?> encodeHeldFrame({bool recognizeText = true});

  /// Drops the held frame without encoding it.
  Future<void> discardHeldFrame();

  /// Drives the always-visible menu bar recording indicator.
  Future<void> setIndicator({required bool recording, required bool paused});

  /// Actions raised from the indicator's own menu.
  void setIndicatorHandler(void Function(String action)? handler);
}

/// The macOS implementation, over `omi/rewind_capture`.
final class MacRewindCapturePlatform implements RewindCapturePlatform {
  MacRewindCapturePlatform([
    this._channel = const MethodChannel('omi/rewind_capture'),
  ]);

  final MethodChannel _channel;
  void Function(String action)? _handler;

  @override
  void setIndicatorHandler(void Function(String action)? handler) {
    _handler = handler;
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      _handler?.call(call.method);
      return null;
    });
  }

  @override
  Future<RewindSystemState> readState() async {
    final raw = await _invoke<Map<Object?, Object?>>('state');
    if (raw == null) return RewindSystemState.unavailable;
    final idleSeconds = raw['idleSeconds'];
    return RewindSystemState(
      context: rewindContextFromMap(raw),
      idleFor: Duration(
        milliseconds: idleSeconds is num
            ? (idleSeconds * 1000).round().clamp(0, 1 << 40)
            : 0,
      ),
      locked: raw['locked'] as bool? ?? false,
      permitted: raw['permitted'] as bool? ?? false,
    );
  }

  @override
  Future<List<RewindDisplay>> displays() async {
    final raw = await _invoke<List<Object?>>('displays');
    if (raw == null) return const [];
    return raw
        .whereType<Map>()
        .map((display) {
          num number(String key, [num fallback = 0]) =>
              display[key] is num ? display[key] as num : fallback;
          return RewindDisplay(
            id: number('id').toInt().toString(),
            name: display['name'] as String? ?? 'Display',
            x: number('x').toInt(),
            y: number('y').toInt(),
            width: number('width').toInt(),
            height: number('height').toInt(),
            scale: number('scale', 1).toDouble(),
            primary: display['primary'] as bool? ?? false,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<Uint8List?> preview(RewindDisplay display) =>
      _invoke<Uint8List>('preview', {'displayId': int.tryParse(display.id)});

  @override
  Future<RewindEncodedFrame?> encodeHeldFrame({
    bool recognizeText = true,
  }) async => RewindEncodedFrame.fromMap(
    await _invoke<Map<Object?, Object?>>('encodeHeldFrame', {
      'recognizeText': recognizeText,
    }),
  );

  @override
  Future<void> discardHeldFrame() async {
    await _invoke<Object>('discardHeldFrame');
  }

  @override
  Future<void> setIndicator({
    required bool recording,
    required bool paused,
  }) async {
    await _invoke<Object>('indicator', {
      'recording': recording,
      'paused': paused,
    });
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// A capture platform that never captures. Used on every platform that is not
/// macOS, and in the settings window's engine, where the controls must work
/// but a second capture loop must not exist.
final class InertRewindCapturePlatform implements RewindCapturePlatform {
  const InertRewindCapturePlatform();

  @override
  Future<RewindSystemState> readState() async => RewindSystemState.unavailable;

  @override
  Future<List<RewindDisplay>> displays() async => const [];

  @override
  Future<Uint8List?> preview(RewindDisplay display) async => null;

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
