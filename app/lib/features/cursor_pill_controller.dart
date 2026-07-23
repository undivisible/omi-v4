import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../app_services.dart';
import '../currents/currents.dart';
import '../keyboard/shift_gesture.dart';
import '../native/native_hub.dart';
import 'cursor_pill_window.dart';
import 'overlay_launcher.dart';
import 'voice_intents.dart';

enum CursorPillState { hidden, input, listening, working }

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
    this._voiceLevelSink,
    this._submitRelay,
    this._chooseRelay,
    String Function()? requestId,
    DateTime Function()? now,
    this.doubleShiftDebounce = const Duration(milliseconds: 500),
    this._currents,
    this._draft,
    this._automate,
    this._openApp,
    this._decideProposal,
    this.draftTimeout = const Duration(milliseconds: 2500),
    this.predictionDebounce = const Duration(milliseconds: 300),
    this.predictionTimeout = const Duration(milliseconds: 1500),
    this.emailLookupTimeout = const Duration(milliseconds: 800),
    this.openFlashDuration = const Duration(milliseconds: 900),
  }) : _launchLink = launchLink ?? launcher.launchUrl,
       _requestId = requestId ?? _defaultRequestId,
       _now = now ?? DateTime.now {
    _voiceNotice?.addListener(_notify);
    if (_voiceLevelSink != null) level.addListener(_forwardVoiceLevel);
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
      // Overlay submissions are agent instructions, not plain chat: the hub
      // frames them so the model acts as the user's desktop agent.
      sendPrompt: (text) =>
          services.sendChatMessage(text: text, origin: MessageOrigin.overlay),
      openApp: const OverlayAppLauncher().openApp,
      decideProposal: (proposalId, decision) => services.decideChatApproval(
        proposalId: proposalId,
        decision: decision,
      ),
      level: CombinedVoiceLevel([
        services.desktopVoice.level,
        services.liveVoice.level,
      ]),
      voiceNotice: services.voiceNotice,
      openHub: openHub,
      presentWindow: (centered) =>
          centered ? CursorPillWindow.summon() : VoiceOverlayWindow.start(),
      dismissWindow: () async {
        await CursorPillWindow.restore();
        await VoiceOverlayWindow.stop();
      },
      voiceLevelSink: VoiceOverlayWindow.level,
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
  final Future<String?> Function(String text) _sendPrompt;
  final VoidCallback? _openHub;
  final Future<bool> Function(Uri link) _launchLink;
  final Future<void> Function(bool centered)? _presentWindow;
  final Future<void> Function()? _dismissWindow;
  final Future<void> Function(double level)? _voiceLevelSink;

  /// Set only inside the pill panel's own Flutter engine, which renders the
  /// overlay but owns none of the services behind it: [submit] and [choose]
  /// hand the raw text (or the suggestion's index) to the primary engine
  /// instead of acting locally, so the launcher, browser, memory, and agent
  /// plumbing all stay in one place.
  final Future<void> Function(String text)? _submitRelay;
  final Future<void> Function(int index)? _chooseRelay;
  final String Function() _requestId;
  final DateTime Function() _now;
  final Duration doubleShiftDebounce;
  final ValueListenable<double> level;
  final ValueListenable<String?>? _voiceNotice;
  final CurrentsController? _currents;
  final Future<String?> Function(String prompt, Duration timeout)? _draft;
  final Future<void> Function(String currentId)? _automate;
  final Future<String?> Function(String query)? _openApp;
  final Future<void> Function(String proposalId, ApprovalDecision decision)?
  _decideProposal;
  final Duration draftTimeout;

  /// How long typing must pause before an inline AI completion is requested,
  /// and how long that request may take before it is abandoned. The
  /// completion renders as the dimmed ghost remainder after the caret.
  final Duration predictionDebounce;
  final Duration predictionTimeout;
  static const predictionMinChars = 3;
  final Duration emailLookupTimeout;

  /// How long the "Opening …" confirmation lingers before the overlay
  /// collapses after a deterministic launch.
  final Duration openFlashDuration;
  Completer<List<MemorySearchItem>>? _emailLookup;
  String? _emailLookupRequestId;
  String? _prediction;
  Timer? _predictionTimer;
  int _predictionEpoch = 0;

  DateTime? _lastTransitionAt;
  CursorPillState _state = CursorPillState.hidden;
  List<PillSuggestion> _suggestions = const [];
  List<PillSuggestion> _currentSuggestions = const [];
  List<PillSuggestion> _memorySuggestions = const [];
  String? _error;
  String? _searchRequestId;
  StreamSubscription<NativeEvent>? _subscription;
  bool _disposed = false;
  String? _status;
  String? _agentRequestId;
  bool _sawAgentReply = false;
  ActionProposal? _proposal;
  int _workingEpoch = 0;

  CursorPillState get state => _state;
  List<PillSuggestion> get suggestions => _suggestions;
  String? get error => _error;

  /// One-line live status while the overlay is working ("Opening Chrome…",
  /// the current tool name/detail streamed by the hub).
  String? get status => _status;

  /// A pending action proposal from an overlay-initiated agent turn,
  /// surfaced next to the overlay so approving is one click. The praefectus
  /// approval flow stays authoritative: this only relays the decision.
  ActionProposal? get proposal => _proposal;

  /// One-line status from the voice pipeline (e.g. a live-voice downgrade
  /// note), shown while listening.
  String? get notice => _voiceNotice?.value;

  Future<void> handleGesture(ShiftGestureAction action) async {
    switch (action) {
      case ShiftGestureAction.toggleVoice:
        await doubleShift();
      case ShiftGestureAction.openOverlay:
        await toggleOverlay();
      case ShiftGestureAction.escape:
        await dismissSurface();
      case ShiftGestureAction.startVoice:
        await beginVoice();
      case ShiftGestureAction.stopVoice:
        await finishListening();
      case ShiftGestureAction.cancel:
        await dismiss();
    }
  }

  /// The chord twice (or a cursor shake mapped through startVoice): talk.
  /// From idle it starts listening immediately (native edge glow plus the
  /// follow-cursor waveform); while any surface is up (voice or overlay) it
  /// dismisses, exactly like Esc. The 500ms debounce guards against a
  /// bounced or double-fired chord.
  Future<void> doubleShift() async {
    if (!_debounced()) return;
    switch (_state) {
      case CursorPillState.hidden:
        await beginVoice();
      case CursorPillState.input ||
          CursorPillState.listening ||
          CursorPillState.working:
        await dismissSurface();
    }
  }

  /// The single chord, Option+Space, or the menu-bar capture control:
  /// summon the text input next to the cursor from idle, dismiss whatever
  /// surface is up otherwise.
  Future<void> toggleOverlay() async {
    if (!_debounced()) return;
    switch (_state) {
      case CursorPillState.hidden:
        await summon();
      case CursorPillState.input ||
          CursorPillState.listening ||
          CursorPillState.working:
        await dismissSurface();
    }
  }

  bool _debounced() {
    final at = _now();
    final last = _lastTransitionAt;
    if (last != null && at.difference(last) < doubleShiftDebounce) {
      return false;
    }
    _lastTransitionAt = at;
    return true;
  }

  /// The shared dismissal Esc and a second chord both perform: with the
  /// overlay up (typing or working) it hides; while listening it stops voice
  /// and routes any transcript (hub intent included); from idle a no-op.
  Future<void> dismissSurface() async {
    switch (_state) {
      case CursorPillState.hidden:
        return;
      case CursorPillState.input || CursorPillState.working:
        await _hide();
      case CursorPillState.listening:
        await finishListening();
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
    // Voice never touches the main window: the edge glow lives in its own
    // click-through overlay window and the waveform in a small panel that
    // follows the cursor, both rendered natively.
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

  /// Called by the overlay on every edit of the in-progress input. Debounces
  /// a short AI continuation request through the draft plumbing; the result
  /// shows as the ghost remainder while the typed text stays a prefix of it.
  /// Typing again cancels the in-flight request (its epoch goes stale), so a
  /// late reply never flashes an outdated completion.
  void inputChanged(String text) {
    _predictionTimer?.cancel();
    _predictionTimer = null;
    _predictionEpoch += 1;
    if (_prediction case final prediction?
        when !_matchesPrediction(prediction, text)) {
      _prediction = null;
      _notify();
    }
    if (_draft == null || _state != CursorPillState.input) return;
    final typed = text;
    if (typed.trim().length < predictionMinChars) return;
    if (_prediction != null) return;
    _predictionTimer = Timer(
      predictionDebounce,
      () => unawaited(_requestPrediction(typed)),
    );
  }

  static bool _matchesPrediction(String prediction, String typed) =>
      typed.isNotEmpty &&
      prediction.length > typed.length &&
      prediction.toLowerCase().startsWith(typed.toLowerCase());

  /// The dimmed ghost continuation for the current [typed] text, or null
  /// when no valid prediction extends it.
  String? predictedRemainder(String typed) {
    final prediction = _prediction;
    if (prediction == null || !_matchesPrediction(prediction, typed)) {
      return null;
    }
    return prediction.substring(typed.length);
  }

  Future<void> _requestPrediction(String typed) async {
    final draft = _draft;
    if (draft == null) return;
    final epoch = _predictionEpoch;
    String? completion;
    try {
      completion = await draft(
        'Continue this partially typed instruction to a desktop assistant. '
        'Reply with only the most likely short continuation of the text — '
        'no quotes, no restating what was already typed, one line.\n'
        'Typed so far: "$typed"',
        predictionTimeout,
      );
    } catch (_) {
      completion = null;
    }
    if (_disposed ||
        epoch != _predictionEpoch ||
        _state != CursorPillState.input) {
      return;
    }
    final cleaned = completion
        ?.replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^["“”]+|["“”]+$'), '')
        .trimRight();
    if (cleaned == null || cleaned.isEmpty) return;
    // The model may either continue the text or restate it in full; fold
    // both shapes into one full predicted string.
    final full = cleaned.toLowerCase().startsWith(typed.toLowerCase())
        ? cleaned
        : '$typed$cleaned';
    if (!_matchesPrediction(full, typed)) return;
    _prediction = full;
    _notify();
  }

  void _clearPrediction() {
    _predictionTimer?.cancel();
    _predictionTimer = null;
    _predictionEpoch += 1;
    _prediction = null;
  }

  Future<void> submit(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty || _state != CursorPillState.input) return;
    if (_submitRelay case final relay?) {
      _clearPrediction();
      await relay(normalized);
      return;
    }
    switch (parseLauncherIntent(normalized)) {
      case OpenUrlIntent(:final url, :final display):
        _showWorking('Opening $display…');
        try {
          await _launchLink(url);
        } catch (_) {}
        _flashThenHide();
      case LaunchAppIntent(:final query):
        if (await _launchApp(query)) return;
        await _sendToAgent(normalized);
      case null:
        await _sendToAgent(normalized);
    }
  }

  /// Resolves and opens an installed app by name via the native launcher.
  /// True when the app launched (the overlay flashes "Opening …" and
  /// collapses); false lets the caller fall through to the assistant.
  Future<bool> _launchApp(String query) async {
    final openApp = _openApp;
    if (openApp == null) return false;
    _showWorking('Opening $query…');
    String? name;
    try {
      name = await openApp(query);
    } catch (_) {
      name = null;
    }
    if (_disposed || _state != CursorPillState.working) return true;
    if (name == null) {
      _state = CursorPillState.input;
      _status = null;
      _notify();
      return false;
    }
    _status = 'Opening $name…';
    _notify();
    _flashThenHide();
    return true;
  }

  /// Routes the typed instruction to the assistant as the user's desktop
  /// agent. The overlay stays up in a working state streaming tool progress;
  /// it collapses when the reply starts streaming in chat (or when the turn
  /// completes silently), and holds open while a proposal awaits approval.
  Future<void> _sendToAgent(String text) async {
    _showWorking('Working on it…');
    _sawAgentReply = false;
    _proposal = null;
    String? requestId;
    try {
      requestId = await _sendPrompt(text);
    } catch (_) {
      requestId = null;
    }
    if (_disposed || _state != CursorPillState.working) return;
    if (requestId == null) {
      await _hide();
      return;
    }
    _agentRequestId = requestId;
  }

  void _showWorking(String status) {
    _clearPrediction();
    _state = CursorPillState.working;
    _status = status;
    _error = null;
    _agentRequestId = null;
    _proposal = null;
    _suggestions = const [];
    _currentSuggestions = const [];
    _memorySuggestions = const [];
    _workingEpoch += 1;
    _notify();
  }

  void _flashThenHide() {
    final epoch = _workingEpoch;
    unawaited(
      Future<void>.delayed(openFlashDuration).then((_) {
        if (_disposed ||
            _state != CursorPillState.working ||
            _workingEpoch != epoch) {
          return;
        }
        unawaited(_hide());
      }),
    );
  }

  /// Relays the user's one-click decision on a surfaced proposal to the
  /// existing approval pipeline, then collapses the overlay.
  Future<void> decideProposal(ApprovalDecision decision) async {
    final proposal = _proposal;
    final decide = _decideProposal;
    if (proposal == null || decide == null) return;
    _proposal = null;
    _notify();
    try {
      await decide(proposal.proposalId, decision);
    } catch (_) {}
    if (!_disposed && _state == CursorPillState.working) await _hide();
  }

  Future<void> choose(PillSuggestion suggestion) async {
    if (_state != CursorPillState.input) return;
    if (_chooseRelay case final relay?) {
      final index = _suggestions.indexOf(suggestion);
      if (index >= 0) await relay(index);
      return;
    }
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
    _clearPrediction();
    _state = CursorPillState.hidden;
    _searchRequestId = null;
    _status = null;
    _agentRequestId = null;
    _sawAgentReply = false;
    _proposal = null;
    _workingEpoch += 1;
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
    if (_state == CursorPillState.working && _agentRequestId != null) {
      if (event case NativeEventToolProgress(
        :final value,
      ) when value.requestId == _agentRequestId) {
        _status = value.detail ?? value.tool.replaceAll('_', ' ');
        _notify();
        return;
      }
      if (event case NativeEventActionProposal(
        :final value,
      ) when value.requestId == _agentRequestId) {
        _proposal = value;
        _notify();
        return;
      }
      if (event case NativeEventAssistantDelta(
        :final value,
      ) when value.requestId == _agentRequestId) {
        if (value.text.isNotEmpty) _sawAgentReply = true;
        // A streaming text reply lives in chat, exactly as before; the
        // overlay's job is done the moment text starts (or when the turn
        // ends silently with nothing to approve).
        if (_sawAgentReply || (value.finalSegment && _proposal == null)) {
          unawaited(_hide());
        }
        return;
      }
      if (event case NativeEventError(
        :final value,
      ) when value.requestId == _agentRequestId) {
        unawaited(_hide());
        return;
      }
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

  /// Adopts the surface state pushed by the primary engine. Only the pill
  /// panel's engine calls this: it renders what the live controller holds
  /// without running the state machine that produced it.
  void applyHostState({
    required CursorPillState state,
    List<PillSuggestion> suggestions = const [],
    String? status,
    String? error,
  }) {
    if (state == CursorPillState.hidden) _clearPrediction();
    _state = state;
    _suggestions = List.unmodifiable(
      state == CursorPillState.input ? suggestions : const <PillSuggestion>[],
    );
    _status = status;
    _error = error;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Relays the live audio level to the native voice surfaces while
  /// listening, so the glow swell and waveform bars track the mic.
  void _forwardVoiceLevel() {
    if (_disposed || _state != CursorPillState.listening) return;
    unawaited(_voiceLevelSink?.call(level.value));
  }

  @override
  void dispose() {
    _disposed = true;
    _predictionTimer?.cancel();
    if (_voiceLevelSink != null) level.removeListener(_forwardVoiceLevel);
    _voiceNotice?.removeListener(_notify);
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  static String _defaultRequestId() =>
      'cursor-pill-${DateTime.now().microsecondsSinceEpoch}';
}
