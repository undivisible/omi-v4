import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../app_services.dart';
import '../currents/currents.dart';
import '../keyboard/shift_gesture.dart';
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

final _evidenceTagPattern = RegExp(
  r'\b(?:MAIL SUBJECT|NOTE TITLE|BROWSING|FILE|FOLDER|EVENT|APP|DOC(?:UMENT)?)'
  r'\s*:\s*',
);
final _senderMetaPattern = RegExp(
  r'\s*\((?:from|to|with|via|sent|cc)\b[^)]*(?:\)|$)',
  caseSensitive: false,
);
final _angleAddressPattern = RegExp(r'\s*<[^<>\s]+@[^<>\s]+>');
final _replyPrefixPattern = RegExp(
  r'^(?:re|fwd?)\s*:\s*',
  caseSensitive: false,
);

/// Strips internal evidence formatting from a string before it is shown to
/// the user or handed to anything external (chip labels, mailto subjects,
/// prompts): the uppercase evidence tags the scanner emits ("MAIL SUBJECT:",
/// "NOTE TITLE:", …), sender-metadata parentheticals ("(from Luke …)", even
/// when truncation lost the closing paren), bare angle-bracket addresses,
/// and collapsed whitespace, capped at [maxLength].
String sanitizeEvidenceText(String text, {int maxLength = 72}) {
  var cleaned = text
      .replaceAll(_evidenceTagPattern, '')
      .replaceAll(_senderMetaPattern, '')
      .replaceAll(_angleAddressPattern, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  cleaned = cleaned
      .replaceAll(RegExp(r'^[\s\-–—…]+'), '')
      .replaceAll(RegExp(r'[\s\-–—…]+$'), '');
  if (cleaned.length > maxLength) {
    cleaned = '${cleaned.substring(0, maxLength - 1).trimRight()}…';
  }
  return cleaned;
}

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
    this.evidence,
  });

  final String label;
  final String prompt;
  final Uri? link;
  final PillSuggestionKind kind;
  final String? currentId;
  final String? personHint;
  final String? email;

  /// The raw evidence text the suggestion was derived from. Never shown or
  /// sent anywhere external verbatim — it feeds subject extraction and gives
  /// the draft model context about the underlying thread.
  final String? evidence;

  static PillSuggestion? fromMemory(MemorySearchItem item) {
    final excerpt = item.excerpt.trim();
    final label = sanitizeEvidenceText(excerpt);
    if (label.isEmpty) return null;
    final email = _emailPattern.firstMatch(excerpt)?.group(0);
    return PillSuggestion(
      label: label,
      prompt: sanitizeEvidenceText(excerpt, maxLength: 280),
      kind: email == null ? PillSuggestionKind.chat : PillSuggestionKind.email,
      email: email,
      link: email == null ? null : Uri(scheme: 'mailto', path: email),
      evidence: excerpt,
    );
  }

  /// Builds an action-aware suggestion from an AI-generated task card.
  /// URLs are only ever taken verbatim from the task text, never invented.
  static PillSuggestion fromCurrent(CurrentCard card) {
    final haystack =
        '${card.title} ${card.summary} ${card.item.proposedNextStep}';
    final url = _urlPattern.firstMatch(haystack)?.group(0);
    final email = _emailPattern.firstMatch(haystack)?.group(0);
    final label = sanitizeEvidenceText(card.title);
    final summary = sanitizeEvidenceText(card.summary, maxLength: 280);
    final prompt = 'Help me with this task: $label. $summary';
    if (url != null) {
      final link = Uri.tryParse(url);
      if (link != null && (link.scheme == 'https' || link.scheme == 'http')) {
        return PillSuggestion(
          label: label,
          prompt: prompt,
          kind: PillSuggestionKind.link,
          link: link,
          currentId: card.item.id,
          evidence: haystack,
        );
      }
    }
    if (email != null || _emailIntentPattern.hasMatch(haystack)) {
      return PillSuggestion(
        label: label,
        prompt: prompt,
        kind: PillSuggestionKind.email,
        email: email,
        personHint: _personPattern.firstMatch(label)?.group(1),
        currentId: card.item.id,
        evidence: haystack,
      );
    }
    return PillSuggestion(
      label: label,
      prompt: prompt,
      currentId: card.item.id,
      evidence: haystack,
    );
  }

  /// A clean subject for an outgoing email about this suggestion: when the
  /// evidence carries a known mail thread ("MAIL SUBJECT: …"), a reply
  /// subject on that thread; otherwise the sanitized task label.
  String get emailSubject {
    final tagged = RegExp(
      r'MAIL SUBJECT:\s*([^\n]+)',
    ).firstMatch(evidence ?? '');
    if (tagged != null) {
      final thread = sanitizeEvidenceText(
        tagged.group(1)!.replaceFirst(_replyPrefixPattern, ''),
        maxLength: 120,
      );
      if (thread.isNotEmpty) return 'Re: $thread';
    }
    return sanitizeEvidenceText(label, maxLength: 120);
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
    this._voiceNotice,
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
       _now = now ?? DateTime.now {
    _voiceNotice?.addListener(_notify);
  }

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
      voiceNotice: services.voiceNotice,
      openHub: openHub,
      presentWindow: (centered) => CursorPillWindow.summon(centered: centered),
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
  final Future<void> Function(bool centered)? _presentWindow;
  final Future<void> Function()? _dismissWindow;
  final String Function() _requestId;
  final DateTime Function() _now;
  final Duration doubleShiftDebounce;
  final ValueListenable<double> level;
  final ValueListenable<String?>? _voiceNotice;
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
  List<PillSuggestion> _currentSuggestions = const [];
  List<PillSuggestion> _memorySuggestions = const [];
  String? _error;
  String? _searchRequestId;
  StreamSubscription<NativeEvent>? _subscription;
  bool _disposed = false;

  CursorPillState get state => _state;
  List<PillSuggestion> get suggestions => _suggestions;
  String? get error => _error;

  /// One-line status from the voice pipeline (e.g. a live-voice downgrade
  /// note), shown while listening.
  String? get notice => _voiceNotice?.value;

  Future<void> handleGesture(ShiftGestureAction action) async {
    switch (action) {
      case ShiftGestureAction.voiceToggle:
        await doubleShift();
      case ShiftGestureAction.openOverlay:
        await toggleOverlay();
      case ShiftGestureAction.startVoice:
        await beginVoice();
      case ShiftGestureAction.stopVoice:
        await finishListening();
      case ShiftGestureAction.cancel:
        await dismiss();
    }
  }

  /// Both-Shift chord: talk directly. From idle (or with the text overlay
  /// open) it drops straight into live voice — only the waveform shows near
  /// the cursor; while already listening it stops. The 500ms debounce guards
  /// against a bounced or double-fired chord.
  Future<void> doubleShift() async {
    final at = _now();
    final last = _lastTransitionAt;
    if (last != null && at.difference(last) < doubleShiftDebounce) return;
    _lastTransitionAt = at;
    switch (_state) {
      case CursorPillState.hidden || CursorPillState.input:
        await beginVoice();
      case CursorPillState.listening:
        await finishListening();
    }
  }

  /// Option+Space (or the menu-bar capture control): toggle the centered text
  /// overlay. Summoning it while voice is live cancels the voice session
  /// first — opening one surface always closes the other.
  Future<void> toggleOverlay() async {
    switch (_state) {
      case CursorPillState.input:
        await dismiss();
      case CursorPillState.hidden || CursorPillState.listening:
        await summon();
    }
  }

  Future<void> beginVoice() async {
    if (_state == CursorPillState.listening) return;
    _state = CursorPillState.listening;
    _error = null;
    _suggestions = const [];
    _currentSuggestions = const [];
    _memorySuggestions = const [];
    _notify();
    // Voice rides the cursor; the waveform, not a pill, is all that shows.
    await _presentWindow?.call(false);
    _subscription ??= _events.listen(_handleEvent);
    try {
      await _startVoice();
    } catch (error) {
      if (_disposed || _state != CursorPillState.listening) return;
      // A dead mic falls back to the text overlay so the message has a
      // surface to live on.
      _state = CursorPillState.input;
      _error = voiceStartErrorMessage(error);
      _notify();
      await _presentWindow?.call(true);
    }
  }

  Future<void> summon() async {
    if (_state == CursorPillState.input) return;
    if (_state == CursorPillState.listening) {
      try {
        await _cancelVoice();
      } catch (_) {}
    }
    _state = CursorPillState.input;
    _error = null;
    _suggestions = const [];
    _currentSuggestions = const [];
    _memorySuggestions = const [];
    _notify();
    await _presentWindow?.call(true);
    _subscription ??= _events.listen(_handleEvent);
    final currents = _currents;
    if (currents != null) {
      final actionable = _actionableCurrents(currents);
      if (actionable.isNotEmpty) {
        _currentSuggestions = actionable;
        _mergeSuggestions();
        _notify();
      } else if (!currents.loading) {
        unawaited(
          currents
              .load()
              .then((_) {
                if (_disposed || _state != CursorPillState.input) return;
                final loaded = _actionableCurrents(currents);
                if (loaded.isNotEmpty) {
                  _currentSuggestions = loaded;
                  _mergeSuggestions();
                  _notify();
                }
              })
              .catchError((_) {}),
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

  /// Task suggestions from the Currents pipeline take priority; when fewer
  /// than three are available, memory-search-derived items fill the
  /// remaining slots (deduplicated by label).
  void _mergeSuggestions() {
    final seen = <String>{};
    final merged = <PillSuggestion>[];
    for (final suggestion in _currentSuggestions.followedBy(
      _memorySuggestions,
    )) {
      if (merged.length == 3) break;
      if (seen.add(suggestion.label.toLowerCase())) merged.add(suggestion);
    }
    _suggestions = List.unmodifiable(merged);
  }

  static String voiceStartErrorMessage(Object error) =>
      switch (error is VoiceStartException ? error.failure : null) {
        VoiceStartFailure.microphonePermission =>
          'Microphone access is off for Omi. Enable it in System Settings → '
              'Privacy & Security → Microphone, then try again.',
        VoiceStartFailure.signedOut =>
          error is VoiceStartException && error.message.isNotEmpty
              ? error.message
              : 'Voice needs a signed-in session. Open Omi and sign in first.',
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
    var address = suggestion.email;
    final draft = _draft;
    var contextItems = const <MemorySearchItem>[];
    if (address == null || draft != null) {
      final person = suggestion.personHint ?? suggestion.label;
      contextItems = await _searchMemory('$person ${suggestion.label} email');
      if (address == null) {
        for (final item in contextItems) {
          address = _emailPattern.firstMatch(item.excerpt)?.group(0);
          if (address != null) break;
        }
      }
    }
    if (address == null) {
      try {
        await _sendPrompt(suggestion.prompt);
      } catch (_) {}
      return;
    }
    String? body;
    if (draft != null) {
      final context = <String>[
        if (suggestion.evidence?.trim() case final evidence?
            when evidence.isNotEmpty)
          evidence,
        for (final item in contextItems.take(3))
          if (item.excerpt.trim() case final excerpt when excerpt.isNotEmpty)
            excerpt.length > 300 ? excerpt.substring(0, 300) : excerpt,
      ];
      try {
        body = await draft(
          'Write a complete, ready-to-send email for this task: '
          '"${suggestion.label}". Include a natural greeting, a friendly '
          '3-6 sentence body that references the relevant details from the '
          'context below, and a brief sign-off. Reply with only the email '
          'text — no subject line and no placeholders.\n'
          'Context from my notes and mail:\n'
          '${context.map((line) => '- $line').join('\n')}',
          draftTimeout,
        );
      } catch (_) {
        body = null;
      }
    }
    final query = StringBuffer(
      'subject=${Uri.encodeComponent(suggestion.emailSubject)}',
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

  Future<List<MemorySearchItem>> _searchMemory(String query) async {
    final requestId = _requestId();
    final completer = Completer<List<MemorySearchItem>>();
    _emailLookup = completer;
    _emailLookupRequestId = requestId;
    try {
      _hub.search(requestId: requestId, query: query, limit: 8);
    } catch (_) {
      _emailLookup = null;
      _emailLookupRequestId = null;
      return const [];
    }
    try {
      return await completer.future.timeout(emailLookupTimeout);
    } on TimeoutException {
      return const [];
    } finally {
      _emailLookup = null;
      _emailLookupRequestId = null;
    }
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
    _currentSuggestions = const [];
    _memorySuggestions = const [];
    _error = null;
    _notify();
    await _dismissWindow?.call();
  }

  void _handleEvent(NativeEvent event) {
    // A live voice session that dies while the pill is listening (provider
    // hung up, connection lost) would otherwise leave the pill stuck on
    // "Listening…" with a dead waveform: the capture layer tears the session
    // down silently. Treat it as a stop so the pill closes cleanly and any
    // transcript that was already received still routes (hub intent included).
    if (event case NativeEventLiveVoiceState(
      value: LiveVoiceState(
        state: LiveVoicePhase.ended || LiveVoicePhase.failed,
      ),
    ) when _state == CursorPillState.listening) {
      unawaited(finishListening());
      return;
    }
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
      final items = List.of(value.items)
        ..sort(
          (a, b) => b.relevanceBasisPoints.compareTo(a.relevanceBasisPoints),
        );
      _memorySuggestions = List.unmodifiable(
        items.map(PillSuggestion.fromMemory).nonNulls.take(3),
      );
      _mergeSuggestions();
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _voiceNotice?.removeListener(_notify);
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  static String _defaultRequestId() =>
      'cursor-pill-${DateTime.now().microsecondsSinceEpoch}';
}
