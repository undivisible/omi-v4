import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../app_services.dart';
import '../keyboard/shift_gesture.dart';
import '../native/generated/signals/signals.dart';
import '../native/native_hub.dart';
import 'cursor_pill_window.dart';
import 'voice_intents.dart';

enum CursorPillState { hidden, input, listening }

final class CombinedVoiceLevel extends ChangeNotifier
    implements ValueListenable<double> {
  CombinedVoiceLevel(this._sources) {
    for (final source in _sources) {
      source.addListener(_changed);
    }
  }

  final List<ValueListenable<double>> _sources;
  double _value = 0;

  @override
  double get value => _value;

  void _changed() {
    var next = 0.0;
    for (final source in _sources) {
      if (source.value > next) next = source.value;
    }
    if (next != _value) {
      _value = next;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (final source in _sources) {
      source.removeListener(_changed);
    }
    super.dispose();
  }
}

final _emailPattern = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');

@immutable
final class PillSuggestion {
  const PillSuggestion({required this.label, required this.prompt, this.link});

  final String label;
  final String prompt;
  final Uri? link;

  static PillSuggestion? fromMemory(MemorySearchItem item) {
    final excerpt = item.excerpt.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (excerpt.isEmpty) return null;
    final label = excerpt.length > 72
        ? '${excerpt.substring(0, 71)}…'
        : excerpt;
    final email = _emailPattern.firstMatch(excerpt)?.group(0);
    return PillSuggestion(
      label: label,
      prompt: excerpt,
      link: email == null ? null : Uri(scheme: 'mailto', path: email),
    );
  }
}

final class CursorPillController extends ChangeNotifier {
  CursorPillController({
    required this._hub,
    required this._events,
    required this._startVoice,
    required this._stopVoice,
    required this._cancelVoice,
    required this._sendPrompt,
    required this.level,
    this._openHub,
    Future<bool> Function(Uri link)? launchLink,
    this._presentWindow,
    this._dismissWindow,
    String Function()? requestId,
    DateTime Function()? now,
    this.doubleShiftDebounce = const Duration(milliseconds: 500),
  }) : _launchLink = launchLink ?? launcher.launchUrl,
       _requestId = requestId ?? _defaultRequestId,
       _now = now ?? DateTime.now;

  factory CursorPillController.forServices(
    AppServices services, {
    VoidCallback? openHub,
  }) {
    services.desktopVoiceIntentInterceptor = matchesShowHubIntent;
    return CursorPillController(
      hub: services.nativeHub,
      events: services.nativeEvents,
      startVoice: services.startDesktopVoice,
      stopVoice: () async => (await services.stopDesktopVoice())?.text ?? '',
      cancelVoice: services.cancelDesktopVoice,
      sendPrompt: (text) => services.sendChatMessage(text: text),
      level: CombinedVoiceLevel([
        services.desktopVoice.level,
        services.liveVoice.level,
      ]),
      openHub: openHub,
      presentWindow: CursorPillWindow.summon,
      dismissWindow: CursorPillWindow.restore,
    );
  }

  static const suggestionQuery = 'follow up task email todo reminder next step';

  final NativeHub _hub;
  final Stream<NativeEvent> _events;
  final Future<void> Function() _startVoice;
  final Future<String> Function() _stopVoice;
  final Future<void> Function() _cancelVoice;
  final Future<void> Function(String text) _sendPrompt;
  final VoidCallback? _openHub;
  final Future<bool> Function(Uri link) _launchLink;
  final Future<void> Function()? _presentWindow;
  final Future<void> Function()? _dismissWindow;
  final String Function() _requestId;
  final DateTime Function() _now;
  final Duration doubleShiftDebounce;
  final ValueListenable<double> level;

  DateTime? _lastTransitionAt;
  CursorPillState _state = CursorPillState.hidden;
  List<PillSuggestion> _suggestions = const [];
  String? _error;
  String? _searchRequestId;
  StreamSubscription<NativeEvent>? _subscription;
  bool _disposed = false;

  CursorPillState get state => _state;
  List<PillSuggestion> get suggestions => _suggestions;
  String? get error => _error;

  Future<void> handleGesture(ShiftGestureAction action) async {
    switch (action) {
      case ShiftGestureAction.openTextInput ||
          ShiftGestureAction.submitText ||
          ShiftGestureAction.startVoice ||
          ShiftGestureAction.stopVoice:
        await doubleShift();
      case ShiftGestureAction.continueVoice:
        break;
      case ShiftGestureAction.cancel:
        await dismiss();
    }
  }

  Future<void> doubleShift() async {
    final at = _now();
    final last = _lastTransitionAt;
    if (last != null && at.difference(last) < doubleShiftDebounce) return;
    _lastTransitionAt = at;
    switch (_state) {
      case CursorPillState.hidden:
        await summon();
      case CursorPillState.input:
        await beginListening();
      case CursorPillState.listening:
        await finishListening();
    }
  }

  Future<void> summon() async {
    if (_state != CursorPillState.hidden) return;
    _state = CursorPillState.input;
    _error = null;
    _suggestions = const [];
    _notify();
    await _presentWindow?.call();
    _subscription ??= _events.listen(_handleEvent);
    final requestId = _requestId();
    _searchRequestId = requestId;
    try {
      _hub.search(requestId: requestId, query: suggestionQuery, limit: 8);
    } catch (_) {
      _searchRequestId = null;
    }
  }

  Future<void> beginListening() async {
    if (_state != CursorPillState.input) return;
    _state = CursorPillState.listening;
    _error = null;
    _notify();
    try {
      await _startVoice();
    } catch (_) {
      if (_disposed || _state != CursorPillState.listening) return;
      _state = CursorPillState.input;
      _error = 'I couldn’t start listening. Check the microphone.';
      _notify();
    }
  }

  Future<void> finishListening() async {
    if (_state != CursorPillState.listening) return;
    String text;
    try {
      text = await _stopVoice();
    } catch (_) {
      text = '';
    }
    await _hide();
    if (text.isNotEmpty && matchesShowHubIntent(text)) _openHub?.call();
  }

  Future<void> submit(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty || _state != CursorPillState.input) return;
    await _hide();
    if (matchesShowHubIntent(normalized)) {
      _openHub?.call();
      return;
    }
    try {
      await _sendPrompt(normalized);
    } catch (_) {}
  }

  Future<void> choose(PillSuggestion suggestion) async {
    if (_state != CursorPillState.input) return;
    await _hide();
    final link = suggestion.link;
    if (link != null) {
      try {
        if (await _launchLink(link)) return;
      } catch (_) {}
    }
    try {
      await _sendPrompt(suggestion.prompt);
    } catch (_) {}
  }

  Future<void> dismiss() async {
    if (_state == CursorPillState.hidden) return;
    if (_state == CursorPillState.listening) {
      try {
        await _cancelVoice();
      } catch (_) {}
    }
    await _hide();
  }

  Future<void> _hide() async {
    _state = CursorPillState.hidden;
    _searchRequestId = null;
    _suggestions = const [];
    _error = null;
    _notify();
    await _dismissWindow?.call();
  }

  void _handleEvent(NativeEvent event) {
    if (event case NativeEventMemorySearchResults(
      :final value,
    ) when value.requestId == _searchRequestId) {
      final items = List.of(value.items)
        ..sort(
          (a, b) => b.relevanceBasisPoints.compareTo(a.relevanceBasisPoints),
        );
      _suggestions = List.unmodifiable(
        items.map(PillSuggestion.fromMemory).nonNulls.take(3),
      );
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  static String _defaultRequestId() =>
      'cursor-pill-${DateTime.now().microsecondsSinceEpoch}';
}
