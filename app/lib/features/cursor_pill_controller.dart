import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../app_services.dart';
import '../currents/currents.dart';
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
final _urlPattern = RegExp(r'https?://[^\s<>"\)\]]+');
final _emailIntentPattern = RegExp(
  r'\b(follow up|email|reply|respond|reach out|write to|ping|message)\b',
  caseSensitive: false,
);
final _personPattern = RegExp(
  r'\b(?:with|to)\s+([A-Z][a-zA-Z]+(?:\s+[A-Z][a-zA-Z]+)?)',
);

enum PillSuggestionKind { chat, email, link }

@immutable
final class PillSuggestion {
  const PillSuggestion({
    required this.label,
    required this.prompt,
    this.link,
    this.kind = PillSuggestionKind.chat,
    this.currentId,
    this.personHint,
    this.email,
  });

  final String label;
  final String prompt;
  final Uri? link;
  final PillSuggestionKind kind;
  final String? currentId;
  final String? personHint;
  final String? email;

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
      kind: email == null ? PillSuggestionKind.chat : PillSuggestionKind.email,
      email: email,
      link: email == null ? null : Uri(scheme: 'mailto', path: email),
    );
  }

  /// Builds an action-aware suggestion from an AI-generated task card.
  /// URLs are only ever taken verbatim from the task text, never invented.
  static PillSuggestion fromCurrent(CurrentCard card) {
    final haystack =
        '${card.title} ${card.summary} ${card.item.proposedNextStep}';
    final url = _urlPattern.firstMatch(haystack)?.group(0);
    final email = _emailPattern.firstMatch(haystack)?.group(0);
    final title = card.title.trim();
    final label = title.length > 72 ? '${title.substring(0, 71)}…' : title;
    if (url != null) {
      final link = Uri.tryParse(url);
      if (link != null && (link.scheme == 'https' || link.scheme == 'http')) {
        return PillSuggestion(
          label: label,
          prompt: 'Help me with this task: $title. ${card.summary}',
          kind: PillSuggestionKind.link,
          link: link,
          currentId: card.item.id,
        );
      }
    }
    if (email != null || _emailIntentPattern.hasMatch(haystack)) {
      return PillSuggestion(
        label: label,
        prompt: 'Help me with this task: $title. ${card.summary}',
        kind: PillSuggestionKind.email,
        email: email,
        personHint: _personPattern.firstMatch(title)?.group(1),
        currentId: card.item.id,
      );
    }
    return PillSuggestion(
      label: label,
      prompt: 'Help me with this task: $title. ${card.summary}',
      currentId: card.item.id,
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
    this._currents,
    this._draft,
    this._automate,
    this.draftTimeout = const Duration(milliseconds: 2500),
    this.emailLookupTimeout = const Duration(milliseconds: 800),
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
      currents: services.currents,
      draft: services.generateDraft,
      automate: services.currents == null
          ? null
          : (currentId) async {
              final handoff = await services.currents!.accept(currentId);
              await services.handoffCurrentAction(handoff);
            },
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
  final CurrentsController? _currents;
  final Future<String?> Function(String prompt, Duration timeout)? _draft;
  final Future<void> Function(String currentId)? _automate;
  final Duration draftTimeout;
  final Duration emailLookupTimeout;
  Completer<List<MemorySearchItem>>? _emailLookup;
  String? _emailLookupRequestId;

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
    final currents = _currents;
    if (currents != null) {
      final actionable = _actionableCurrents(currents);
      if (actionable.isNotEmpty) {
        _suggestions = actionable;
        _notify();
        return;
      }
      if (!currents.loading) {
        unawaited(
          currents.load().then((_) {
            if (_disposed || _state != CursorPillState.input) return;
            final loaded = _actionableCurrents(currents);
            if (loaded.isNotEmpty) {
              _suggestions = loaded;
              _notify();
            }
          }).catchError((_) {}),
        );
      }
    }
    final requestId = _requestId();
    _searchRequestId = requestId;
    try {
      _hub.search(requestId: requestId, query: suggestionQuery, limit: 8);
    } catch (_) {
      _searchRequestId = null;
    }
  }

  static List<PillSuggestion> _actionableCurrents(
    CurrentsController currents,
  ) => List.unmodifiable(
    currents.items
        .where((card) => !card.item.isTerminal)
        .take(3)
        .map(PillSuggestion.fromCurrent),
  );

  Future<void> beginListening() async {
    if (_state != CursorPillState.input) return;
    _state = CursorPillState.listening;
    _error = null;
    _notify();
    try {
      await _startVoice();
    } catch (error) {
      if (_disposed || _state != CursorPillState.listening) return;
      _state = CursorPillState.input;
      _error = voiceStartErrorMessage(error);
      _notify();
    }
  }

  static String voiceStartErrorMessage(Object error) =>
      switch (error is VoiceStartException ? error.failure : null) {
        VoiceStartFailure.microphonePermission =>
          'Microphone access is off for Omi. Enable it in System Settings → '
              'Privacy & Security → Microphone, then try again.',
        VoiceStartFailure.signedOut =>
          'Voice needs a signed-in session. Open Omi and sign in first.',
        VoiceStartFailure.backendNotConfigured =>
          'No voice service is set up yet. Add a transcription provider in '
              'Settings to use voice.',
        VoiceStartFailure.network =>
          'I couldn’t reach the voice service. Check your connection and try '
              'again.',
        VoiceStartFailure.unsupportedPlatform =>
          'Voice isn’t available on this platform.',
        null => 'I couldn’t start listening. Check the microphone.',
      };

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
    switch (suggestion.kind) {
      case PillSuggestionKind.link:
        await _hide();
        final link = suggestion.link;
        if (link != null) {
          try {
            await _launchLink(link);
          } catch (_) {}
        }
        // Hand the task off to the computer-use pipeline when available;
        // opening the URL above already gave the user something immediate.
        final currentId = suggestion.currentId;
        final automate = _automate;
        if (currentId != null && automate != null) {
          unawaited(automate(currentId).catchError((_) {}));
        }
      case PillSuggestionKind.email:
        await _dispatchEmail(suggestion);
      case PillSuggestionKind.chat:
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
  }

  Future<void> _dispatchEmail(PillSuggestion suggestion) async {
    await _hide();
    final address =
        suggestion.email ??
        await _resolveEmail(suggestion.personHint ?? suggestion.label);
    if (address == null) {
      try {
        await _sendPrompt(suggestion.prompt);
      } catch (_) {}
      return;
    }
    String? body;
    final draft = _draft;
    if (draft != null) {
      try {
        body = await draft(
          'Draft a short, friendly 2-3 sentence email for this task: '
          '"${suggestion.prompt}". Reply with only the email body text — '
          'no subject line, no signature, no placeholders.',
          draftTimeout,
        );
      } catch (_) {
        body = null;
      }
    }
    final query = StringBuffer(
      'subject=${Uri.encodeComponent(suggestion.label)}',
    );
    if (body != null && body.trim().isNotEmpty) {
      query.write('&body=${Uri.encodeComponent(body.trim())}');
    }
    final mailto = Uri(scheme: 'mailto', path: address, query: '$query');
    try {
      if (await _launchLink(mailto)) return;
    } catch (_) {}
    try {
      await _sendPrompt(suggestion.prompt);
    } catch (_) {}
  }

  Future<String?> _resolveEmail(String person) async {
    final requestId = _requestId();
    final completer = Completer<List<MemorySearchItem>>();
    _emailLookup = completer;
    _emailLookupRequestId = requestId;
    try {
      _hub.search(requestId: requestId, query: '$person email', limit: 8);
    } catch (_) {
      _emailLookup = null;
      _emailLookupRequestId = null;
      return null;
    }
    List<MemorySearchItem> items;
    try {
      items = await completer.future.timeout(emailLookupTimeout);
    } on TimeoutException {
      items = const [];
    } finally {
      _emailLookup = null;
      _emailLookupRequestId = null;
    }
    for (final item in items) {
      final email = _emailPattern.firstMatch(item.excerpt)?.group(0);
      if (email != null) return email;
    }
    return null;
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
    ) when value.requestId == _emailLookupRequestId) {
      _emailLookupRequestId = null;
      final lookup = _emailLookup;
      _emailLookup = null;
      if (lookup != null && !lookup.isCompleted) {
        lookup.complete(List.of(value.items));
      }
      return;
    }
    if (event case NativeEventMemorySearchResults(
      :final value,
    ) when value.requestId == _searchRequestId) {
      // Task suggestions from the Currents pipeline take priority; memory
      // search results only fill in when no task cards are available.
      if (_suggestions.any((item) => item.currentId != null)) return;
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
