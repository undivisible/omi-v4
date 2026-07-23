import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../native/native_hub.dart';
import 'ax_context.dart';
import 'cursor_pill.dart';
import 'cursor_pill_controller.dart';

/// The channel the primary Flutter engine answers on: the Runner relays every
/// action the panel takes here, and the shell pushes render state back the
/// same way.
const pillHostChannelName = 'omi/pill_host';

/// The channel inside the pill panel's own engine, owned natively by
/// PillPanelController.
const pillPanelChannelName = 'omi/pill';

String _stateName(CursorPillState state) => switch (state) {
  CursorPillState.hidden => 'hidden',
  CursorPillState.input => 'input',
  CursorPillState.listening => 'listening',
  CursorPillState.working => 'working',
};

CursorPillState _stateFrom(Object? name) => switch (name) {
  'input' => CursorPillState.input,
  'listening' => CursorPillState.listening,
  'working' => CursorPillState.working,
  _ => CursorPillState.hidden,
};

/// The primary engine's half of the pill-panel bridge. It never renders
/// anything: it mirrors the live [CursorPillController] into the panel's
/// engine and executes the actions the panel relays back, so the launcher,
/// browser, memory search, and agent all keep running in the one engine that
/// owns the services.
final class PillPanelHost {
  PillPanelHost({
    required this._controller,
    this._draft,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(pillHostChannelName);

  final CursorPillController _controller;
  final Future<String?> Function(String prompt, Duration timeout)? _draft;
  final MethodChannel _channel;

  void start() {
    _channel.setMethodCallHandler(handle);
    _controller.addListener(push);
  }

  void dispose() {
    _controller.removeListener(push);
    _channel.setMethodCallHandler(null);
  }

  @visibleForTesting
  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'submit':
        await _controller.submit(call.arguments as String? ?? '');
        return null;
      case 'choose':
        final index = call.arguments as int? ?? -1;
        final suggestions = _controller.suggestions;
        if (index >= 0 && index < suggestions.length) {
          await _controller.choose(suggestions[index]);
        }
        return null;
      case 'voice':
        await _controller.beginVoice();
        return null;
      case 'dismiss':
        await _controller.dismiss();
        return null;
      case 'completion':
        final arguments = call.arguments as Map?;
        final draft = _draft;
        if (draft == null) return null;
        return draft(
          arguments?['prompt'] as String? ?? '',
          Duration(milliseconds: arguments?['timeoutMs'] as int? ?? 1500),
        );
      case 'axContext':
        // The panel's engine cannot reach the omi/ax_context channel, which is
        // registered only on the primary engine; relay the read-only snapshot
        // it captured across so the panel's inline assist has on-screen context.
        return (await AxContext.snapshot()).toMap();
      case 'sync':
        push();
        return null;
      default:
        throw MissingPluginException(call.method);
    }
  }

  /// Mirrors the controller's surface into the panel. Suggestions travel as
  /// plain labels plus their index: acting on one is relayed back by index so
  /// the primary engine dispatches the real thing.
  void push() {
    unawaited(
      _channel
          .invokeMethod<void>('pushState', {
            'state': _stateName(_controller.state),
            'suggestions': [
              for (final suggestion in _controller.suggestions)
                {'label': suggestion.label, 'kind': suggestion.kind.name},
            ],
            'status': _controller.status,
            'error': _controller.error,
          })
          .catchError((_) {}),
    );
  }
}

/// The panel engine's half of the bridge: a [CursorPillController] whose
/// actions are all relayed to the primary engine, wrapped in the handlers the
/// Runner drives (show, hide, pushed state).
final class PillPanelClient {
  PillPanelClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(pillPanelChannelName) {
    controller = CursorPillController(
      hub: const UnavailableNativeHub('pill panel'),
      events: const Stream.empty(),
      // Voice is never hosted in the panel: its glow and waveform are native
      // windows driven by the primary engine, so the mic button closes this
      // panel and asks the host to start listening.
      startVoice: () async {
        await _invoke('close');
        await _invoke('voice');
      },
      stopVoice: () async => '',
      cancelVoice: () async {},
      sendPrompt: (text) async => null,
      submitRelay: (text) => _invoke('submit', text),
      chooseRelay: (index) => _invoke('choose', index),
      dismissWindow: () => _invoke('dismiss'),
      draft: (prompt, timeout) => _completion(prompt, timeout),
      fetchAxContext: _axContext,
      level: ValueNotifier<double>(0),
    );
  }

  final MethodChannel _channel;
  late final CursorPillController controller;

  void start() {
    _channel.setMethodCallHandler(handle);
    unawaited(_ready());
  }

  /// The Runner may have shown the panel before this engine finished booting;
  /// the handshake recovers that first summon instead of rendering nothing.
  Future<void> _ready() async {
    Map<Object?, Object?>? reply;
    try {
      reply = await _channel.invokeMethod<Map<Object?, Object?>>('ready');
    } catch (_) {
      return;
    }
    if (reply?['visible'] == true) {
      controller.applyHostState(state: CursorPillState.input);
    }
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<String?> _completion(String prompt, Duration timeout) async {
    try {
      return await _channel.invokeMethod<String>('completion', {
        'prompt': prompt,
        'timeoutMs': timeout.inMilliseconds,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<AxContextSnapshot> _axContext() async {
    try {
      final reply = await _channel.invokeMethod<Map<Object?, Object?>>(
        'axContext',
      );
      return reply == null
          ? AxContextSnapshot.empty
          : AxContextSnapshot.fromMap(reply);
    } on MissingPluginException {
      return AxContextSnapshot.empty;
    } on PlatformException {
      return AxContextSnapshot.empty;
    }
  }

  @visibleForTesting
  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'show':
        controller.applyHostState(state: CursorPillState.input);
      case 'hide':
        controller.applyHostState(state: CursorPillState.hidden);
      case 'state':
        final arguments = call.arguments as Map?;
        final state = _stateFrom(arguments?['state']);
        controller.applyHostState(
          state: state,
          suggestions: [
            for (final raw in (arguments?['suggestions'] as List?) ?? const [])
              if (raw is Map)
                PillSuggestion(
                  label: raw['label'] as String? ?? '',
                  prompt: raw['label'] as String? ?? '',
                  kind: PillSuggestionKind.values.firstWhere(
                    (kind) => kind.name == raw['kind'],
                    orElse: () => PillSuggestionKind.chat,
                  ),
                ),
          ],
          status: arguments?['status'] as String?,
          error: arguments?['error'] as String?,
        );
        // Anything but the typing surface belongs to the hub or the native
        // voice windows; the panel closes rather than mirroring it.
        if (state != CursorPillState.input) await _invoke('close');
      default:
        throw MissingPluginException(call.method);
    }
    return null;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    controller.dispose();
  }
}

/// Reports the pill's rounded-rect glass regions (logical points, top-left
/// origin) to the panel's native Liquid Glass layer so it masks itself to the
/// Flutter layout above it. Outside the panel's engine the channel is absent
/// and the call is a no-op.
abstract final class PillPanelGlass {
  static const _channel = MethodChannel(pillPanelChannelName);

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static Future<void> update(
    List<({double x, double y, double w, double h, double r})> regions, {
    double radius = 18,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('glass', {
        'regions': [
          for (final region in regions)
            {
              'x': region.x,
              'y': region.y,
              'w': region.w,
              'h': region.h,
              'r': region.r,
            },
        ],
        'radius': radius,
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}

/// The whole app inside the pill panel's engine: only the overlay, on a
/// transparent surface, so the native glass shows through behind it.
class PillPanelApp extends StatefulWidget {
  const PillPanelApp({this.client, super.key});

  final PillPanelClient? client;

  @override
  State<PillPanelApp> createState() => _PillPanelAppState();
}

class _PillPanelAppState extends State<PillPanelApp> {
  late final PillPanelClient _client = widget.client ?? PillPanelClient();

  @override
  void initState() {
    super.initState();
    _client.start();
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Omi',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, fontFamily: 'SF Pro Display'),
    home: Scaffold(
      backgroundColor: Colors.transparent,
      body: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: CursorPill(
            controller: _client.controller,
            // The panel is always summoned over another app, where the reader
            // can see the thread and the draft in progress — invite that.
            hintText: 'Ask about what you’re working on…',
          ),
        ),
      ),
    ),
  );
}
