import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../native/native_hub.dart';
import '../../storage/omi_directory.dart';
import 'rewind_platform.dart';

/// One exchange with the hub's Rewind engine: a request in, exactly one
/// payload out. Null means the hub never answered — it is unavailable, or the
/// answer did not arrive inside [RewindClient.responseTimeout].
typedef RewindTransport =
    Future<RewindPayload?> Function(RewindRequest request);

/// How long a single exchange may take before the client gives up on it. The
/// engine's work is a lock and a file write, so anything near this is a wedged
/// bridge rather than a slow disk, and the pump must be able to recover from
/// it without stranding a held frame.
const _defaultResponseTimeout = Duration(seconds: 10);

/// The client half of the Rewind capture handshake.
///
/// The engine — the policy, the privacy rules, the store, the retention
/// bounds — lives in the Rust hub. What has to stay here is the capture
/// surface itself, because reading the screen and running Apple's Vision text
/// recognition are platform calls behind `omi/rewind_capture`, and the hub
/// cannot reach across the bridge to make them.
///
/// So this class owns the loop and the hub owns the decisions. Each tick it
/// samples the machine's state, asks the hub what to do, and does exactly the
/// one thing it is told. That is what carries the frame-economy invariant
/// across the move: [RewindCapturePlatform.preview] holds the full frame
/// natively and returns 72 bytes of luminance, the hub decides from those 72
/// bytes, and [RewindCapturePlatform.encodeHeldFrame] is only ever called when
/// the answer came back [RewindDirectiveEncode]. No frame is ever encoded and
/// then thrown away.
final class RewindClient extends ChangeNotifier {
  RewindClient({
    required this.transport,
    this.platform = const InertRewindCapturePlatform(),
    this.tickInterval = const Duration(seconds: 3),
    this.captures = true,
    this.responseTimeout = _defaultResponseTimeout,
  });

  /// Builds a client over the real hub, correlating each answer with the
  /// request that asked for it.
  factory RewindClient.overHub({
    required NativeHub hub,
    RewindCapturePlatform platform = const InertRewindCapturePlatform(),
    Duration tickInterval = const Duration(seconds: 3),
    bool captures = true,
  }) {
    final pending = <String, Completer<RewindPayload>>{};
    var sequence = 0;
    final subscription = hub.events.listen((event) {
      if (event is! NativeEventRewind) return;
      final waiting = pending.remove(event.value.requestId);
      if (waiting != null && !waiting.isCompleted) {
        waiting.complete(event.value.payload);
      }
    });
    late final RewindClient client;
    client = RewindClient(
      transport: (request) async {
        final requestId = 'rewind-${sequence++}';
        final completer = Completer<RewindPayload>();
        pending[requestId] = completer;
        try {
          hub.rewind(requestId: requestId, request: request);
        } on NativeHubUnavailable {
          pending.remove(requestId);
          return null;
        }
        try {
          return await completer.future.timeout(client.responseTimeout);
        } on TimeoutException {
          pending.remove(requestId);
          return null;
        }
      },
      platform: platform,
      tickInterval: tickInterval,
      captures: captures,
    );
    client._onDispose = () {
      unawaited(subscription.cancel());
      pending.clear();
    };
    return client;
  }

  final RewindTransport transport;
  final RewindCapturePlatform platform;
  final Duration tickInterval;
  final Duration responseTimeout;

  /// False for a client that only reads the engine's state, so that no second
  /// capture loop is ever opened alongside the primary engine's.
  final bool captures;

  Timer? _timer;
  bool _inFlight = false;
  bool _disposed = false;
  void Function()? _onDispose;

  RewindStatus? _status;
  List<RewindFrameRecord> _frames = const [];
  RewindSystemState _systemState = RewindSystemState.unavailable;
  String? _unavailable;

  /// The engine's published state, or null before the first answer arrives.
  RewindStatus? get status => _status;

  /// Why the engine could not be reached, when it could not be. Null once it
  /// has answered anything.
  String? get unavailableReason => _unavailable;

  /// The most recent page of frames, newest first.
  List<RewindFrameRecord> get frames => _frames;

  RewindSystemState get systemState => _systemState;

  bool get recording => _status?.recording ?? false;
  RewindSkipReason? get lastSkipReason => _status?.lastSkipReason;

  /// Opens the timeline and starts the loop. The root is resolved here rather
  /// than in the hub because `~/.omi` is the app's convention and every other
  /// local store already reads it from the same place.
  Future<void> initialize() async {
    final base = await omiDataDirectory();
    final payload = await transport(
      RewindRequestOpen(root: '${base.path}${Platform.pathSeparator}rewind'),
    );
    _apply(payload);
    platform.setIndicatorHandler(_indicatorAction);
    await _syncIndicator();
    await refreshFrames();
    _startTimer();
    _notify();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      tickInterval,
      (_) => unawaited(captures ? pump() : refreshStatus()),
    );
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

  /// One turn of the capture handshake. Public so the loop can be driven
  /// deterministically in tests instead of by wall-clock timers.
  Future<void> pump() async {
    if (_disposed || _inFlight) return;
    _inFlight = true;
    // Set the moment the native side is holding a full frame, and cleared the
    // moment it stops. The `finally` below is the only guarantee that a frame
    // the handshake abandoned does not sit in native memory: every early
    // return from here passes through it.
    var holding = false;
    try {
      final state = await platform.readState();
      _systemState = state;
      final displays = await platform.displays();
      var stored = false;
      for (final display in displays) {
        final first = await transport(
          RewindRequestTick(
            context: state.context,
            display: display,
            idleMs: state.idleFor.inMilliseconds,
            locked: state.locked,
            permitted: state.permitted,
          ),
        );
        final opening = _directiveOf(first);
        if (opening is! RewindDirectivePreview) {
          _apply(first);
          continue;
        }
        final stepId = _stepIdOf(first);
        if (stepId == null) continue;

        final luma = await platform.preview(display);
        holding = luma != null;
        final second = await transport(
          RewindRequestPreviewTaken(
            stepId: stepId,
            luma: luma ?? const <int>[],
          ),
        );
        final verdict = _directiveOf(second);
        if (verdict is! RewindDirectiveEncode) {
          // Either the similarity gate rejected it or the capture failed. The
          // full frame is still sitting in native memory, unencoded; the
          // `finally` drops it.
          if (holding) await platform.discardHeldFrame();
          holding = false;
          continue;
        }

        final encoded = await platform.encodeHeldFrame(
          recognizeText: verdict.recognizeText,
        );
        // Encoding consumes the held frame whether or not it produced bytes.
        holding = false;
        final third = await transport(
          RewindRequestFrameEncoded(
            stepId: stepId,
            jpeg: encoded?.jpeg ?? const <int>[],
            ocrText: encoded?.ocrText,
          ),
        );
        if (_directiveOf(third) is RewindDirectiveStored) {
          stored = true;
        }
      }
      if (stored) await refreshFrames();
    } finally {
      if (holding) await platform.discardHeldFrame();
      _inFlight = false;
      if (!_disposed) await refreshStatus();
    }
  }

  Future<void> refreshStatus() async {
    _apply(await transport(const RewindRequestStatus()));
  }

  Future<void> refreshFrames({int limit = 200}) async {
    _apply(await transport(RewindRequestListFrames(limit: limit)));
  }

  /// Local, on-device search over the recognized text.
  Future<void> search(String query, {int limit = 200}) async {
    if (query.trim().isEmpty) {
      await refreshFrames(limit: limit);
      return;
    }
    _apply(await transport(RewindRequestSearch(query: query, limit: limit)));
  }

  Future<void> setEnabled(bool enabled) async {
    _apply(await transport(RewindRequestSetEnabled(enabled: enabled)));
    if (!enabled) await platform.discardHeldFrame();
    await _syncIndicator();
  }

  Future<void> setPaused(bool paused) async {
    _apply(await transport(RewindRequestSetPaused(paused: paused)));
    if (paused) await platform.discardHeldFrame();
    await _syncIndicator();
  }

  Future<void> setRetention(RewindRetentionOption option) async {
    _apply(
      await transport(
        RewindRequestSetRetention(
          maxAgeDays: option.maxAgeDays,
          maxBytes: option.maxBytes,
        ),
      ),
    );
    await refreshFrames();
  }

  Future<void> setPrivacyFlags({
    bool? skipPrivateBrowsing,
    bool? recordWindowTitles,
    bool? readOnScreenText,
  }) async {
    final current = _status;
    if (current == null) return;
    _apply(
      await transport(
        RewindRequestSetPrivacyFlags(
          skipPrivateBrowsing:
              skipPrivateBrowsing ?? current.skipPrivateBrowsing,
          recordWindowTitles: recordWindowTitles ?? current.recordWindowTitles,
          readOnScreenText: readOnScreenText ?? current.readOnScreenText,
        ),
      ),
    );
  }

  Future<void> denyBundleId(String bundleId) async {
    if (bundleId.trim().isEmpty) return;
    _apply(await transport(RewindRequestDenyBundleId(bundleId: bundleId)));
  }

  Future<void> allowBundleId(String bundleId) async {
    _apply(await transport(RewindRequestAllowBundleId(bundleId: bundleId)));
  }

  Future<void> deleteAll() async {
    _apply(await transport(const RewindRequestDeleteAll()));
    await refreshFrames();
  }

  Future<void> deleteLast(Duration window) async {
    _apply(
      await transport(RewindRequestDeleteLast(windowMs: window.inMilliseconds)),
    );
    await refreshFrames();
  }

  Future<void> deleteFrame(RewindFrameRecord frame) async {
    _apply(
      await transport(
        RewindRequestDeleteFrame(relativePath: frame.relativePath),
      ),
    );
    await refreshFrames();
  }

  Future<void> _syncIndicator() async {
    final current = _status;
    if (current == null) return;
    await platform.setIndicator(
      recording: current.enabled,
      paused: current.paused,
    );
  }

  void _apply(RewindPayload? payload) {
    switch (payload) {
      case null:
        _unavailable ??= 'The Rewind engine did not answer.';
      case RewindPayloadStatus(:final value):
        _unavailable = null;
        _status = value;
      case RewindPayloadFrames(:final frames):
        _unavailable = null;
        _frames = List.unmodifiable(frames);
      case RewindPayloadUnavailable(:final detail):
        _unavailable = detail;
      case RewindPayloadDirective():
        // Directives drive the handshake in [pump]; they carry no state.
        _unavailable = null;
      default:
        break;
    }
    _notify();
  }

  static RewindDirective? _directiveOf(RewindPayload? payload) =>
      payload is RewindPayloadDirective ? payload.directive : null;

  static Uint64? _stepIdOf(RewindPayload? payload) =>
      payload is RewindPayloadDirective ? payload.stepId : null;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    platform.setIndicatorHandler(null);
    _onDispose?.call();
    super.dispose();
  }
}

/// Process-wide access to the Rewind client. Only the primary engine has one:
/// it is the engine rinf bound the Rust hub to, and the only one that
/// registers the native capture bridge.
final class RewindRuntime {
  RewindRuntime._();

  static final RewindRuntime instance = RewindRuntime._();

  RewindClient? _client;
  Future<RewindClient>? _pending;

  /// [captures] is true for the primary engine, which owns the capture loop.
  Future<RewindClient> resolve({
    required NativeHub hub,
    required bool captures,
  }) {
    final existing = _pending;
    if (existing != null) return existing;
    return _pending = _create(hub: hub, captures: captures);
  }

  RewindClient? get clientOrNull => _client;

  Future<RewindClient> _create({
    required NativeHub hub,
    required bool captures,
  }) async {
    final client = RewindClient.overHub(
      hub: hub,
      platform: captures && rewindSupported
          ? MacRewindCapturePlatform()
          : const InertRewindCapturePlatform(),
      captures: captures && rewindSupported,
    );
    await client.initialize();
    _client = client;
    return client;
  }
}
