import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, ScrollCacheExtent;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/worker_http.dart'
    show BillingEntitlement, OmiPlan, WorkerAuthenticationException;
import '../app_services.dart';
import '../capabilities/hub_platform.dart';
import '../channels/channels.dart';
import '../currents/crepus_current.dart';
import '../currents/currents.dart';
import '../demo/demo_mode.dart';
import '../demo/demo_model.dart';
import '../demo/demo_prompt_bus.dart';
import '../keyboard/keyboard.dart';
import '../native/generated/signals/signals.dart'
    show
        ActionRisk,
        ComputerUseAction,
        ComputerUseActionCapability,
        ComputerUseActionInvoke,
        ComputerUseActionSetValue,
        ComputerUseBackgroundSupport,
        ComputerUseCapabilities,
        ComputerUseDeliveryRoute,
        ComputerUseSessionIsolation,
        ComputerUseTargetProvenance;
import '../native/native_hub.dart';
import '../onboarding/hub_checklist.dart';
import '../ui/assistant_content.dart';
import '../ui/omi_ui.dart';
import 'ax_context.dart';
import 'composer_dictation.dart';
import 'cursor_pill_controller.dart' show CombinedVoiceLevel;
import 'hub_task_meta.dart';
import 'in_app_voice_view.dart';
import 'meeting_notes.dart';
import 'meeting_notes_screen.dart';
import 'tasks_screen.dart';

/// Height of the sliver of conversation left visible above the home view, so
/// the newest message peeks in and scrolling up is discoverable.
const double _historyPeekExtent = 108;

/// Top breathing room inside the live exchange once the send transition lands,
/// so the first turn sits below the status strip instead of hugging it.
const double _exchangeTopInset = 72;

/// Width of the reading column. The scroll surface spans the full viewport;
/// only the content is centered inside this width.
const double _readingColumnMaxWidth = 680;

/// How long a live exchange stays in the viewport after the last turn or app
/// background — aligned with the desktop overlay session reuse window.
const Duration _chatSessionReuseWindow = Duration(seconds: 45);

// ponytail: 120px is roughly one turn's worth of slack. A scroll that ends
// within this of a message boundary settles onto it; a clean flick that lands
// further out between turns is left where it stopped rather than yanked back.
const double _historySnapThreshold = 120;

/// How far past the newest message the pull has to reach before the hold that
/// starts a new conversation begins counting.
const double _newChatPullStart = -56;

/// How long that pull has to be held. A flick is over in a few frames and its
/// spring-back is not a drag at all, so it can never reach this.
const Duration _newChatHold = Duration(milliseconds: 650);

/// How often the held pull repaints its progress bar.
const Duration _newChatPullTick = Duration(milliseconds: 40);

/// The send transition: the greeter leaves and the new message climbs the
/// viewport on this one clock.
const Duration _sendEnterDuration = Duration(milliseconds: 620);

/// Reads the plan this account is on. Null means there is nothing to ask —
/// no billing backend — which is itself a free setup.
typedef EntitlementProbe = Future<BillingEntitlement?> Function();

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.services,
    this.previewMode = false,
    this.desktopKeyboard,
    this.onDesktopGestureReset,
    this.checklistStore,
    this.onOpenProviderSettings,
    this.entitlementProbe,
    this.dictation,
    super.key,
  });

  final AppServices services;
  final bool previewMode;
  final DesktopKeyboard? desktopKeyboard;
  final VoidCallback? onDesktopGestureReset;

  final HubChecklistStore? checklistStore;

  /// Opens settings at the BYOK/provider-keys section, for the hint row under
  /// the task list.
  final VoidCallback? onOpenProviderSettings;

  /// Override for the plan lookup that gates the BYOK hint.
  final EntitlementProbe? entitlementProbe;

  /// Override for composer dictation, so a test can drive the microphone
  /// without a real one.
  final ComposerDictation? dictation;

  @override
  State<ChatScreen> createState() => ChatScreenState();
}

class _HubColors {
  const _HubColors._({
    required this.ink,
    required this.muted,
    required this.hairline,
    required this.hintBlue,
    required this.cardBg,
    required this.cardShadow,
    required this.sendBg,
    required this.sendFg,
    required this.sendDisabledBg,
    required this.rowHover,
    required this.focusRing,
  });

  const _HubColors.light()
    : this._(
        ink: const Color(0xff171716),
        muted: const Color(0xff756b61),
        hairline: const Color(0x1a000000),
        hintBlue: const Color(0xff4d6976),
        cardBg: const Color(0xfffbf4e9),
        cardShadow: const Color(0x0a000000),
        sendBg: const Color(0xff24383d),
        sendFg: Colors.white,
        sendDisabledBg: const Color(0x33171716),
        rowHover: const Color(0x8cfbf4e9),
        focusRing: const Color(0x40171716),
      );

  const _HubColors.dark()
    : this._(
        ink: const Color(0xfff4f2ea),
        muted: const Color(0xffa6a49c),
        hairline: const Color(0x1affffff),
        hintBlue: const Color(0xffa1beb9),
        cardBg: const Color(0xff302a27),
        cardShadow: const Color(0x33000000),
        sendBg: const Color(0xffe5d6bc),
        sendFg: const Color(0xff201a17),
        sendDisabledBg: const Color(0x33e5d6bc),
        rowHover: const Color(0x14ffffff),
        focusRing: const Color(0x59fffcec),
      );

  final Color ink;
  final Color muted;
  final Color hairline;
  final Color hintBlue;
  final Color cardBg;
  final Color cardShadow;
  final Color sendBg;
  final Color sendFg;
  final Color sendDisabledBg;
  final Color rowHover;
  final Color focusRing;

  static _HubColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const _HubColors.dark()
      : const _HubColors.light();
}

const _kPlaceholderPrompts = [
  'Turn today’s notes into a plan',
  'What should I do next?',
  'What did I do last week in the terminal?',
  'Draft the desktop handoff',
];

class ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();

  /// Composer dictation. Absent without a backend to transcribe through, in
  /// which case the microphone is simply not offered.
  late final ComposerDictation? _dictation =
      widget.dictation ??
      switch (widget.services.voiceNoteTranscriber) {
        final transcribe? => ComposerDictation(transcribe: transcribe),
        null => null,
      };
  Timer? _placeholderTimer;
  int _placeholderIndex = 0;
  String? _localName;
  late final _desktopKeyboard = widget.desktopKeyboard ?? DesktopKeyboard();
  final _messages = <_ChatMessage>[];
  final _proposals = <String, ActionProposal>{};
  final _proposalExpiryTimers = <String, Timer>{};
  StreamSubscription<NativeEvent>? _events;
  StreamSubscription<int>? _authorityChanges;
  Timer? _conversationRefreshTimer;
  final _conversationLoads = <int>{};
  String? _activeRequestId;
  String? _progress;
  String? _error;
  String? _memorySyncNotice;
  ComputerUseCapabilities? _computerUseCapabilities;
  bool _sending = false;
  int _conversationLoadGeneration = 0;
  int _conversationCursor = 0;
  late final HubChecklistStore _checklist =
      widget.checklistStore ?? PreferencesHubChecklistStore();
  static const byokHintDismissedKey = 'hub_byok_hint_dismissed_v1';
  static const chatSessionExchangeStartKey = 'hub_chat_exchange_start_v1';
  static const chatSessionActivityKey = 'hub_chat_session_activity_v1';
  late final EntitlementProbe _entitlementProbe =
      widget.entitlementProbe ??
      () async => widget.previewMode
          ? null
          : await widget.services.billing?.getEntitlement();
  bool _byokHintDismissed = true;
  bool _byokPlanFree = false;
  bool _setupTaskDone = true;

  /// Index into [_messages] of the first message of the exchange currently on
  /// screen. Everything before it is history, parked above the home view; null
  /// means there is no live exchange and the home view owns the viewport.
  int? _exchangeStart;
  late final AnimationController _sendEnter;
  late final CurvedAnimation _sendEntered;
  Timer? _pullTimer;
  double _pullProgress = 0;
  final _scroll = ScrollController();
  final _exchangeKey = GlobalKey();
  final _homeKey = GlobalKey();
  // One key per history message index, so each turn's scroll offset can be
  // measured and used as a snap boundary. Keyed by index to stay stable across
  // rebuilds; a given index is only ever built in history, never the exchange,
  // so the key is never mounted twice.
  final _historyKeys = <int, GlobalKey>{};
  bool _userDragged = false;
  bool _snapping = false;
  bool _pendingChatReveal = false;
  Timer? _chatRevealTimer;
  Timer? _chatSessionExpiryTimer;
  DateTime? _chatSessionActivityAt;
  List<String> _starterTasks = const [];
  final _doneStarterTasks = <String>{};
  List<MeetingNote> _meetingNotes = const [];
  late final _voiceLevel = CombinedVoiceLevel([
    widget.services.desktopVoice.level,
    widget.services.liveVoice.level,
  ]);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sendEnter = AnimationController(vsync: this, duration: _sendEnterDuration);
    _sendEntered = CurvedAnimation(
      parent: _sendEnter,
      // Settles rather than snaps: away quickly, then a long slowing landing.
      curve: const Cubic(.22, 1, .36, 1),
    );
    unawaited(_loadChecklist());
    unawaited(_loadMeetingNotes());
    unawaited(_loadByokHint());
    if (!widget.previewMode) {
      unawaited(
        widget.services.localProfileName().then((value) {
          if (mounted && value != null) setState(() => _localName = value);
        }),
      );
    }
    _placeholderTimer = Timer.periodic(const Duration(milliseconds: 3200), (_) {
      if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
      setState(
        () => _placeholderIndex =
            (_placeholderIndex + 1) % _kPlaceholderPrompts.length,
      );
    });
    // The demo's guided walkthrough types its steps into this composer, so
    // they go through the same send path the keyboard does. `omiDemoMode` is
    // a compile-time constant, so outside that build this is compiled away.
    if (omiDemoMode) DemoPromptBus.instance.attach(_sendPrompt);
    if (!widget.previewMode) {
      widget.services.currents?.addListener(_currentsChanged);
      unawaited(_refreshCurrents());
      unawaited(_loadConversation().then((_) => _restoreChatSession()));
      _events = widget.services.nativeEvents.listen(_handleEvent);
      widget.services.memorySyncNotice.addListener(_memorySyncNoticeChanged);
      _memorySyncNotice = widget.services.memorySyncNotice.value;
      _authorityChanges = widget.services.chatAuthorityChanges.listen((_) {
        if (!mounted) return;
        _conversationLoadGeneration += 1;
        _conversationRefreshTimer?.cancel();
        _conversationRefreshTimer = null;
        _conversationCursor = 0;
        setState(() {
          _messages.clear();
          _activeRequestId = null;
          _proposals.clear();
          for (final timer in _proposalExpiryTimers.values) {
            timer.cancel();
          }
          _proposalExpiryTimers.clear();
          _progress = null;
          _computerUseCapabilities = null;
          _error = 'Chat authority changed. Reconnect before continuing.';
        });
        if (widget.services.auth.snapshot.hasProcessingAuthority) {
          unawaited(_refreshCurrents());
          unawaited(_loadConversation());
        }
      });
    }
  }

  void _currentsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadChecklist() async {
    bool done;
    List<String> starters;
    List<String> doneStarters;
    try {
      done = await _checklist.isSetupComplete();
    } catch (_) {
      done = true;
    }
    try {
      starters = await _checklist.starterTasks();
    } catch (_) {
      starters = const [];
    }
    try {
      doneStarters = await _checklist.doneStarterTasks();
    } catch (_) {
      doneStarters = const [];
    }
    if (mounted &&
        (done != _setupTaskDone ||
            starters.isNotEmpty ||
            doneStarters.isNotEmpty)) {
      setState(() {
        _setupTaskDone = done;
        _starterTasks = starters;
        _doneStarterTasks
          ..clear()
          ..addAll(doneStarters);
      });
    }
  }

  /// Meetings surface as currents, not as a buried settings row: the notes Omi
  /// wrote belong next to "what matters next", where the user is already
  /// looking. Reloaded whenever a meeting completes.
  Future<void> _loadMeetingNotes() async {
    if (!meetingAssistSupported && !widget.previewMode) return;
    List<MeetingNote> notes;
    try {
      notes = await widget.services.meetingNotes.list();
    } catch (_) {
      notes = const [];
    }
    if (!mounted) return;
    setState(() => _meetingNotes = notes);
  }

  void _openMeetingNotes() {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => MeetingNotesScreen(services: widget.services),
        fullscreenDialog: true,
      ),
    );
  }

  /// The BYOK hint is only true for accounts that are not already paying for
  /// managed AI, so the plan is checked before it is ever shown. No billing
  /// backend at all (local mode, previews) counts as free.
  Future<void> _loadByokHint() async {
    bool dismissed;
    try {
      dismissed =
          (await SharedPreferences.getInstance()).getBool(
            byokHintDismissedKey,
          ) ??
          false;
    } catch (_) {
      dismissed = false;
    }
    if (!mounted) return;
    setState(() => _byokHintDismissed = dismissed);
    if (dismissed) return;
    BillingEntitlement? entitlement;
    try {
      entitlement = await _entitlementProbe();
    } catch (_) {
      entitlement = null;
    }
    if (!mounted) return;
    setState(
      () => _byokPlanFree =
          entitlement == null ||
          entitlement.plan != OmiPlan.pro ||
          !entitlement.active,
    );
  }

  Future<void> _dismissByokHint() async {
    setState(() => _byokHintDismissed = true);
    try {
      await (await SharedPreferences.getInstance()).setBool(
        byokHintDismissedKey,
        true,
      );
    } catch (_) {}
  }

  void _toggleStarterTask(String title) {
    setState(() {
      if (!_doneStarterTasks.remove(title)) _doneStarterTasks.add(title);
    });
    unawaited(
      _checklist
          .setDoneStarterTasks(_doneStarterTasks.toList())
          .catchError((Object _) {}),
    );
  }

  void _toggleSetupTask() {
    setState(() => _setupTaskDone = !_setupTaskDone);
    unawaited(
      _checklist.setSetupComplete(_setupTaskDone).catchError((Object _) {}),
    );
  }

  String _describeError(Object? failure) {
    debugPrint('chat_screen error: $failure');
    return switch (failure) {
      WorkerAuthenticationException() =>
        'Sign in to sync with your account, or keep chatting locally.',
      CurrentsClientException(:final message) => message,
      StateError(:final message) => message,
      _ => 'Something went wrong. Please try again.',
    };
  }

  Future<void> _refreshCurrents() async {
    final currents = widget.services.currents;
    // Currents come from the worker, so signed out there is nothing to ask
    // for. The demo build is the exception: its currents client is a seeded
    // in-process transport, and `omiDemoMode` is a compile-time constant, so
    // outside that build this reads exactly as it did.
    if (currents == null || !(widget.services.chatReady || omiDemoMode)) return;
    await currents.load();
  }

  Future<void> handleDesktopGesture(ShiftGestureAction action) async {
    if (!mounted) return;
    switch (action) {
      case ShiftGestureAction.toggleVoice:
        await handleDesktopGesture(
          widget.services.desktopVoiceActive
              ? ShiftGestureAction.stopVoice
              : ShiftGestureAction.startVoice,
        );
      case ShiftGestureAction.openOverlay:
        await _desktopKeyboard.focusApplication();
        if (mounted) _inputFocus.requestFocus();
      case ShiftGestureAction.escape:
      case ShiftGestureAction.cancel:
        if (widget.services.desktopVoiceActive) {
          await widget.services.cancelDesktopVoice();
          if (mounted) setState(() => _progress = 'Cancelled');
        } else if (_activeRequestId != null) {
          _cancel();
        } else {
          _input.clear();
          _inputFocus.unfocus();
        }
      case ShiftGestureAction.startVoice:
        if (_activeRequestId != null || _sending) {
          setState(() => _error = 'Finish the current request first.');
          widget.onDesktopGestureReset?.call();
          return;
        }
        try {
          final sessionContext = desktopVoiceSupported
              ? (await AxContext.snapshot()).asSessionContextPrompt(
                  'Screen context for this voice session:',
                )
              : null;
          await widget.services.startDesktopVoice(
            sessionContext: sessionContext,
          );
          if (!mounted) {
            await widget.services.cancelDesktopVoice();
            return;
          }
          setState(() => _progress = 'Listening');
        } catch (failure) {
          widget.onDesktopGestureReset?.call();
          if (mounted) setState(() => _error = _describeError(failure));
        }
      case ShiftGestureAction.stopVoice:
        try {
          final submission = await widget.services.stopDesktopVoice();
          if (!mounted) return;
          setState(() {
            _progress = null;
            if (submission != null) {
              _beginExchange();
              _messages.add(
                _ChatMessage(
                  requestId: submission.requestId,
                  text: submission.text,
                  fromUser: true,
                ),
              );
              _activeRequestId = submission.requestId;
            }
          });
        } catch (failure) {
          if (mounted) setState(() => _error = _describeError(failure));
        }
    }
  }

  Future<void> _loadConversation() async {
    final generation = _conversationLoadGeneration;
    if (!_conversationLoads.add(generation)) return;
    try {
      final messages = await widget.services.replayConversation(
        after: _conversationCursor,
      );
      if (!mounted || generation != _conversationLoadGeneration) return;
      setState(() {
        for (final message in messages) {
          if (_messages.any(
            (existing) =>
                existing.requestId == message.clientMessageId ||
                (!existing.fromUser &&
                    message.role == 'assistant' &&
                    message.clientMessageId ==
                        'assistant:${existing.requestId}'),
          )) {
            continue;
          }
          _messages.add(
            _ChatMessage(
              requestId: message.clientMessageId,
              text: message.text,
              fromUser: message.role == 'user',
            ),
          );
        }
        if (messages.isNotEmpty) {
          _conversationCursor = messages.last.cursor;
        }
      });
    } on WorkerAuthenticationException catch (failure) {
      if (mounted && generation == _conversationLoadGeneration) {
        setState(() => _error = _describeError(failure));
      }
    } catch (failure) {
      debugPrint('chat_screen conversation replay: $failure');
    } finally {
      _conversationLoads.remove(generation);
      if (mounted && generation == _conversationLoadGeneration) {
        _conversationRefreshTimer ??= Timer(const Duration(seconds: 2), () {
          _conversationRefreshTimer = null;
          unawaited(_loadConversation());
        });
      }
    }
  }

  void _memorySyncNoticeChanged() {
    if (!mounted) return;
    setState(() => _memorySyncNotice = widget.services.memorySyncNotice.value);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.previewMode) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        unawaited(_persistChatSession());
      case AppLifecycleState.resumed:
        _maybeExpireChatSession();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_persistChatSession());
    _chatSessionExpiryTimer?.cancel();
    _conversationLoadGeneration += 1;
    _conversationRefreshTimer?.cancel();
    widget.services.currents?.removeListener(_currentsChanged);
    widget.services.memorySyncNotice.removeListener(_memorySyncNoticeChanged);
    widget.onDesktopGestureReset?.call();
    unawaited(widget.services.cancelDesktopVoice());
    unawaited(_events?.cancel());
    unawaited(_authorityChanges?.cancel());
    for (final timer in _proposalExpiryTimers.values) {
      timer.cancel();
    }
    // Only the one this screen made is this screen's to dispose.
    if (omiDemoMode) DemoPromptBus.instance.detach(_sendPrompt);
    if (widget.dictation == null) _dictation?.dispose();
    _placeholderTimer?.cancel();
    _chatRevealTimer?.cancel();
    _pullTimer?.cancel();
    _sendEntered.dispose();
    _sendEnter.dispose();
    _scroll.dispose();
    _voiceLevel.dispose();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// Opens or extends the live exchange around the message about to be added.
  /// The first turn in a session lifts the home view away; follow-ups stay in
  /// the same exchange viewport so the full back-and-forth remains visible.
  void _beginExchange() {
    final openingSession = _exchangeStart == null;
    if (openingSession) {
      _exchangeStart = _messages.length;
    }
    _touchChatSessionActivity();
    _pendingChatReveal = true;
    _chatRevealTimer?.cancel();
    _chatRevealTimer = Timer(const Duration(milliseconds: 450), () {
      _pendingChatReveal = false;
    });
    _cancelNewChatPull();
    if (openingSession) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _sendEnter.value = 1;
      } else {
        _sendEnter.forward(from: 0);
      }
    } else if (_sendEnter.value < 1) {
      _sendEnter.forward(from: _sendEnter.value);
    }
    // The new exchange is the bottom of the reversed list; whatever the user
    // had scrolled to is no longer what they are looking at.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _touchChatSessionActivity() {
    _chatSessionActivityAt = DateTime.now();
    _scheduleChatSessionExpiry();
    unawaited(_persistChatSession());
  }

  void _scheduleChatSessionExpiry() {
    _chatSessionExpiryTimer?.cancel();
    final activityAt = _chatSessionActivityAt;
    if (_exchangeStart == null || activityAt == null) return;
    final remaining =
        _chatSessionReuseWindow - DateTime.now().difference(activityAt);
    _chatSessionExpiryTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      _maybeExpireChatSession,
    );
  }

  void _maybeExpireChatSession() {
    if (!mounted || _exchangeStart == null) return;
    final activityAt = _chatSessionActivityAt;
    if (activityAt == null ||
        DateTime.now().difference(activityAt) >= _chatSessionReuseWindow) {
      _collapseChatSessionToHistory();
    }
  }

  void _collapseChatSessionToHistory() {
    if (!mounted || _exchangeStart == null) return;
    _chatSessionExpiryTimer?.cancel();
    _sendEnter.value = 0;
    setState(() => _exchangeStart = null);
    unawaited(_clearPersistedChatSession());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients && _scroll.offset > 0) {
        _scroll.jumpTo(0);
      }
    });
  }

  Future<void> _restoreChatSession() async {
    if (widget.previewMode || !mounted) return;
    SharedPreferences preferences;
    try {
      preferences = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final activityMs = preferences.getInt(chatSessionActivityKey);
    final exchangeStart = preferences.getInt(chatSessionExchangeStartKey);
    if (activityMs == null || exchangeStart == null) return;
    final activityAt = DateTime.fromMillisecondsSinceEpoch(activityMs);
    if (DateTime.now().difference(activityAt) >= _chatSessionReuseWindow) {
      await _clearPersistedChatSession(preferences: preferences);
      return;
    }
    if (exchangeStart < 0 || exchangeStart > _messages.length) {
      await _clearPersistedChatSession(preferences: preferences);
      return;
    }
    if (!mounted) return;
    setState(() {
      _exchangeStart = exchangeStart;
      _chatSessionActivityAt = activityAt;
      _sendEnter.value = 1;
    });
    _scheduleChatSessionExpiry();
  }

  Future<void> _persistChatSession({SharedPreferences? preferences}) async {
    if (widget.previewMode) return;
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      final start = _exchangeStart;
      final activityAt = _chatSessionActivityAt;
      if (start == null || activityAt == null) {
        await _clearPersistedChatSession(preferences: prefs);
        return;
      }
      await prefs.setInt(chatSessionExchangeStartKey, start);
      await prefs.setInt(
        chatSessionActivityKey,
        activityAt.millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  Future<void> _clearPersistedChatSession({
    SharedPreferences? preferences,
  }) async {
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      await prefs.remove(chatSessionExchangeStartKey);
      await prefs.remove(chatSessionActivityKey);
    } catch (_) {}
  }

  /// Puts the transcript behind the home view again: the pull-and-hold past
  /// the newest message is the "new chat" gesture.
  void _startNewConversation() {
    _cancelNewChatPull();
    if (omiDemoMode) DemoModel.instance.startNewConversation();
    _collapseChatSessionToHistory();
  }

  void _beginNewChatPull() {
    if (_pullTimer != null) return;
    // Counted in ticks rather than off the wall clock: the hold has to advance
    // with the frames the pull is drawn in.
    _pullTimer = Timer.periodic(_newChatPullTick, (_) {
      if (!mounted) return;
      final step =
          _newChatPullTick.inMilliseconds / _newChatHold.inMilliseconds;
      final progress = (_pullProgress + step).clamp(0.0, 1.0);
      setState(() => _pullProgress = progress);
      if (progress >= 1) _startNewConversation();
    });
  }

  void _cancelNewChatPull() {
    _pullTimer?.cancel();
    _pullTimer = null;
    if (_pullProgress != 0 && mounted) setState(() => _pullProgress = 0);
  }

  bool _handleScroll(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (notification is ScrollStartNotification) {
      _cancelNewChatPull();
      _userDragged = notification.dragDetails != null;
      return false;
    }
    if (notification is ScrollUpdateNotification) {
      // Only a live finger counts. The spring-back after a flick reports the
      // same deep overscroll with no drag behind it, and that must never open
      // a new conversation.
      if (notification.dragDetails == null ||
          metrics.pixels > _newChatPullStart ||
          _exchangeStart == null) {
        _cancelNewChatPull();
      } else {
        _userDragged = true;
        _beginNewChatPull();
      }
      return false;
    }
    if (notification is! ScrollEndNotification) return false;
    _cancelNewChatPull();
    // Only a scroll the user drove gets rearranged under them: an
    // ensureVisible that put something on screen must be left alone.
    if (_snapping || !_userDragged || _exchangeStart == null) return false;
    final render = _exchangeKey.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return false;
    // The live exchange, and the home view directly above it. The snap keeps a
    // half-scroll from stranding the user between them.
    final boundary = render.size.height.clamp(0.0, metrics.maxScrollExtent);
    if (boundary <= 0) return false;
    final pixels = metrics.pixels;
    if (pixels <= 1) return false;
    final target = _majoritySnapTarget(
      pixels,
      metrics.viewportDimension,
      boundary,
      metrics.maxScrollExtent,
    );
    if (target == null || (target - pixels).abs() <= 1) return false;
    _snapTo(target);
    return false;
  }

  /// Chooses a snap target from whichever region — live exchange, home
  /// (greeter/currents), or history — occupies the majority of the viewport.
  double? _majoritySnapTarget(
    double pixels,
    double viewportHeight,
    double boundary,
    double maxScrollExtent,
  ) {
    final viewTop = pixels;
    final viewBottom = pixels + viewportHeight;

    double overlap(double regionStart, double regionEnd) {
      final start = math.max(viewTop, regionStart);
      final end = math.min(viewBottom, regionEnd);
      return math.max(0, end - start);
    }

    if (pixels < boundary) {
      final exchangeVisible = overlap(0, boundary);
      final homeVisible = overlap(boundary, viewBottom);
      if (exchangeVisible >= homeVisible) return 0;
      return boundary;
    }

    final homeEnd =
        _homeScrollEnd(boundary, maxScrollExtent) ??
        boundary + viewportHeight * 0.5;
    final homeVisible = overlap(boundary, homeEnd);
    final historyVisible = overlap(
      homeEnd,
      math.max(homeEnd, maxScrollExtent + viewportHeight),
    );
    if (homeVisible >= historyVisible) return boundary;
    return _nearestHistoryStop(pixels, boundary, maxScrollExtent);
  }

  /// Scroll offset of the home slot's trailing edge — where history begins.
  double? _homeScrollEnd(double boundary, double maxScrollExtent) {
    final box = _homeKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;
    final offset = viewport.getOffsetToReveal(box, 1).offset;
    if (!offset.isFinite || offset <= boundary || offset > maxScrollExtent) {
      return null;
    }
    return offset;
  }

  /// The history turn boundary nearest [pixels], or null when there is nothing
  /// above the home view to snap to or the drag ended too far from any boundary
  /// to warrant moving it. Boundaries are measured from each turn's real render
  /// geometry, so variable-height rows (artifacts, skeletons, rich task rows)
  /// each land on their own edge rather than a fixed increment.
  double? _nearestHistoryStop(double pixels, double boundary, double max) {
    final stops = <double>[boundary];
    for (final key in _historyKeys.values) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport == null) continue;
      // Alignment 1, not 0: the list is reversed, so a turn's boundary is
      // reachable when its trailing edge meets the viewport edge. Alignment 0
      // asks for the leading edge and returns offsets past maxScrollExtent for
      // the turns near the top, which can never actually be scrolled to.
      final offset = viewport.getOffsetToReveal(box, 1).offset;
      if (!offset.isFinite || offset <= boundary || offset > max) continue;
      stops.add(offset);
    }
    if (stops.length < 2) return null;
    var best = stops.first;
    var bestDistance = (best - pixels).abs();
    for (final stop in stops.skip(1)) {
      final distance = (stop - pixels).abs();
      if (distance < bestDistance) {
        best = stop;
        bestDistance = distance;
      }
    }
    if (bestDistance > _historySnapThreshold || bestDistance <= 1) return null;
    return best;
  }

  void _snapTo(double target) {
    _snapping = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) {
        _snapping = false;
        return;
      }
      if (MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(target);
        _snapping = false;
        return;
      }
      unawaited(
        _scroll
            .animateTo(
              target,
              duration: const Duration(milliseconds: 340),
              curve: Curves.easeInOutCubic,
            )
            .whenComplete(() => _snapping = false),
      );
    });
  }

  /// Puts the caret in the hub's own composer. The chord means "start
  /// typing", so while omi is already frontmost it lands here instead of
  /// summoning the floating pill panel over the window.
  void focusInput() {
    if (!mounted) return;
    _inputFocus.requestFocus();
  }

  /// Brings the hub to the tasks view — the voice "show me my tasks" intent
  /// lands here.
  void showAllTasks() {
    if (!mounted) return;
    final currents = widget.services.currents;
    if (currents != null) _openAllTasks(currents);
  }

  void _handleEvent(NativeEvent event) {
    if (!mounted) return;
    setState(() {
      switch (event) {
        case NativeEventAssistantDelta(:final value):
          if (value.requestId != _activeRequestId) return;
          final index = _messages.indexWhere(
            (message) =>
                message.requestId == value.requestId && !message.fromUser,
          );
          final message = _ChatMessage(
            requestId: value.requestId,
            text: index == -1
                ? value.text
                : '${_messages[index].text}${value.text}',
            fromUser: false,
          );
          if (index == -1) {
            _messages.add(message);
          } else {
            _messages[index] = message;
          }
          if (value.finalSegment) {
            unawaited(
              widget.services
                  .saveAssistantMessage(
                    requestId: value.requestId,
                    text: message.text,
                  )
                  .catchError((Object failure, _) {
                    debugPrint('chat_screen assistant save: $failure');
                  }),
            );
            _activeRequestId = null;
            _progress = null;
            _touchChatSessionActivity();
          }
        case NativeEventToolProgress(:final value):
          if (value.requestId != _activeRequestId &&
              !value.requestId.startsWith('approval-')) {
            return;
          }
          _progress = [
            value.tool,
            value.status.name,
            if (value.detail != null) value.detail!,
          ].join(' · ');
          if (value.status == ToolStatus.failed ||
              value.status == ToolStatus.cancelled) {
            if (value.requestId == _activeRequestId) {
              _activeRequestId = null;
            }
            _removeProposalsForParent(value.requestId);
          }
        case NativeEventActionProposal(:final value):
          _proposals[value.proposalId] = value;
          _proposalExpiryTimers.remove(value.proposalId)?.cancel();
          if (value.expiresAtMs != null) {
            final remaining =
                value.expiresAtMs! - DateTime.now().millisecondsSinceEpoch;
            _proposalExpiryTimers[value.proposalId] = Timer(
              Duration(milliseconds: remaining > 0 ? remaining : 0),
              () {
                if (!mounted) return;
                setState(() => _proposals.remove(value.proposalId));
                _proposalExpiryTimers.remove(value.proposalId);
              },
            );
          }
        case NativeEventError(:final value):
          final requestId = value.requestId;
          if (requestId == _activeRequestId ||
              (requestId != null && requestId.startsWith('approval-'))) {
            _error = value.message;
            if (requestId == _activeRequestId) {
              _activeRequestId = null;
              _progress = null;
            }
            if (requestId != null) {
              _removeProposalsForParent(requestId);
            }
          }
        case NativeEventRuntimeStatus(:final value):
          _computerUseCapabilities = value.computerUseCapabilities;
        case NativeEventMeetingStateChanged(:final value):
          if (value.active) {
            _progress =
                'Meeting detected: ${value.suggestedTitle ?? 'Meeting'}';
          }
        case NativeEventMeetingInsight(:final value):
          _progress = value.text;
        case NativeEventMeetingCompleted(:final value):
          final requestId =
              'meeting-summary-${DateTime.now().microsecondsSinceEpoch}';
          final text = [
            'Meeting summary: ${value.summary}',
            for (final action in value.actions) '• $action',
          ].join('\n');
          _messages.add(
            _ChatMessage(requestId: requestId, text: text, fromUser: false),
          );
          unawaited(
            widget.services
                .saveAssistantMessage(requestId: requestId, text: text)
                .catchError((Object failure, _) {
                  debugPrint('chat_screen meeting summary save: $failure');
                }),
          );
          unawaited(_loadMeetingNotes());
        default:
          break;
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _activeRequestId != null || _sending) return;
    // A channel link code in the chat box is a link action, not a message for
    // the assistant — redeem it here and confirm inline (bare code or prose
    // that clearly mentions linking). Long prompts are never intercepted.
    final code = ChannelLinkCode.extractFrom(text);
    final channels = widget.services.channels;
    if (code != null && channels != null) {
      await _redeemLinkCode(channels, code, userText: text);
      return;
    }
    _sending = true;
    try {
      final requestId = await widget.services.sendChatMessage(text: text);
      if (!mounted) return;
      setState(() {
        _beginExchange();
        _messages.add(
          _ChatMessage(requestId: requestId, text: text, fromUser: true),
        );
        _activeRequestId = requestId;
        _progress = null;
        _error = null;
        _input.clear();
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _activeRequestId = null;
        _progress = null;
        _error = _describeError(failure);
      });
    } finally {
      _sending = false;
    }
  }

  Future<void> _redeemLinkCode(
    ChannelClient channels,
    String code, {
    required String userText,
  }) async {
    _sending = true;
    setState(() {
      _beginExchange();
      _messages.add(
        _ChatMessage(
          requestId: 'channel-link:$code',
          text: userText,
          fromUser: true,
        ),
      );
      _progress = 'Linking chat';
      _error = null;
      _input.clear();
    });
    try {
      final channel = await channels.redeemCode(code);
      if (!mounted) return;
      final name = channel == ChannelProvider.telegram
          ? 'Telegram'
          : 'iMessage';
      setState(() {
        _messages.add(
          _ChatMessage(
            requestId: 'channel-link-result:$code',
            text: 'Linked your $name chat to this account.',
            fromUser: false,
          ),
        );
        _progress = null;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _progress = null;
        _error = failure is ChannelApiException && failure.statusCode == 404
            ? 'That link code is unknown or has expired. Text the bot again '
                  'for a fresh one.'
            : _describeError(failure);
      });
    } finally {
      _sending = false;
    }
  }

  void _cancel() {
    final requestId = _activeRequestId;
    if (requestId == null) return;
    widget.services.cancelChatRequest(requestId);
    setState(() {
      _activeRequestId = null;
      _progress = 'Cancelled';
      _removeProposalsForParent(requestId);
    });
  }

  void _usePrompt(String prompt) {
    _input.value = TextEditingValue(
      text: prompt,
      selection: TextSelection.collapsed(offset: prompt.length),
    );
    _inputFocus.requestFocus();
  }

  void _sendPrompt(String prompt) {
    _input.value = TextEditingValue(
      text: prompt,
      selection: TextSelection.collapsed(offset: prompt.length),
    );
    unawaited(_send());
  }

  void _removeProposalsForParent(String requestId) {
    final removed = _proposals.values
        .where((proposal) => proposal.requestId == requestId)
        .map((proposal) => proposal.proposalId)
        .toList();
    for (final proposalId in removed) {
      _proposals.remove(proposalId);
      _proposalExpiryTimers.remove(proposalId)?.cancel();
    }
  }

  Future<void> _decide(
    ActionProposal proposal,
    ApprovalDecision decision,
  ) async {
    try {
      await widget.services.decideChatApproval(
        proposalId: proposal.proposalId,
        decision: decision,
      );
      _proposalExpiryTimers.remove(proposal.proposalId)?.cancel();
      setState(() => _proposals.remove(proposal.proposalId));
    } catch (failure) {
      setState(() => _error = _describeError(failure));
    }
  }

  Widget _computerActionDetails(ComputerUseAction action) => switch (action) {
    ComputerUseActionInvoke(:final targetName, :final backgroundOnly) => Text(
      'Invoke “$targetName” · ${backgroundOnly ? 'Background only' : 'Interactive'}',
      key: const Key('computer_action_details'),
    ),
    ComputerUseActionSetValue(
      :final targetName,
      :final value,
      :final backgroundOnly,
    ) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Set “$targetName” to'),
          const SizedBox(height: 4),
          SelectableText(value, key: const Key('computer_action_text')),
          const SizedBox(height: 6),
          Text(
            backgroundOnly ? 'Background only' : 'Interactive',
            key: const Key('computer_action_details'),
          ),
        ],
      ),
    _ => const Text(
      'Unknown computer action',
      key: Key('computer_action_details'),
    ),
  };

  String _riskDetail(ActionRisk risk) => switch (risk) {
    ActionRisk.reversible =>
      'Conservative risk: reversible, but the target and resulting state still require verification.',
    ActionRisk.external =>
      'Conservative risk: external side effect that may affect another person or system.',
    ActionRisk.destructive =>
      'Conservative risk: destructive or difficult to reverse.',
  };

  String _targetDetail(ComputerUseTargetProvenance provenance) =>
      'Fenced target: ${provenance.role} · process ${provenance.processId} '
      '(${provenance.processGeneration}) · window ${provenance.windowId} · '
      'observation ${provenance.observationGeneration}';

  ComputerUseActionCapability? _actionCapability(ComputerUseAction action) {
    final name = switch (action) {
      ComputerUseActionInvoke() => 'invoke',
      ComputerUseActionSetValue() => 'set_value',
      _ => null,
    };
    if (name == null) return null;
    final capabilities = _computerUseCapabilities;
    if (capabilities == null) return null;
    for (final capability in capabilities.actions) {
      if (capability.name == name) return capability;
    }
    return null;
  }

  String _capabilityDetail(ComputerUseAction action) {
    final capabilities = _computerUseCapabilities;
    final capability = _actionCapability(action);
    if (capabilities == null || capability == null || !capability.available) {
      return 'Native host did not report this action as available.';
    }
    final isolation = switch (capabilities.sessionIsolation) {
      ComputerUseSessionIsolation.sharedDesktop =>
        'shared desktop; not session-isolated',
      ComputerUseSessionIsolation.hostIsolated => 'host-isolated session',
      ComputerUseSessionIsolation.unknown => 'session isolation unknown',
    };
    final delivery = switch (capability.deliveryRoute) {
      ComputerUseDeliveryRoute.targetAddressed => 'target-addressed delivery',
      ComputerUseDeliveryRoute.pointer => 'pointer delivery',
      ComputerUseDeliveryRoute.unknown => 'delivery route unknown',
    };
    final background = switch (capability.backgroundSupport) {
      ComputerUseBackgroundSupport.guarded =>
        capabilities.sessionIsolation ==
                ComputerUseSessionIsolation.sharedDesktop
            ? 'guarded shared-desktop background'
            : 'guarded background',
      ComputerUseBackgroundSupport.hostIsolatedOnly =>
        'background requires host isolation',
      ComputerUseBackgroundSupport.unavailable => 'background unavailable',
      ComputerUseBackgroundSupport.unknown => 'background support unknown',
    };
    final permissions = capabilities.permissions
        .map(
          (permission) =>
              '${permission.name} ${permission.granted ? 'granted' : 'denied'}',
        )
        .join(', ');
    return '${capabilities.platform} · ${capabilities.backend} · $isolation · '
        '$delivery · $background · Permissions: '
        '${permissions.isEmpty ? 'none reported' : permissions}';
  }

  bool _canApprove(ActionProposal proposal) {
    final action = proposal.computerAction;
    if (action == null) return true;
    final capability = _actionCapability(action);
    if (proposal.operationId == null ||
        proposal.actionHash == null ||
        proposal.targetProvenance == null ||
        capability == null ||
        !capability.available ||
        capability.deliveryRoute != ComputerUseDeliveryRoute.targetAddressed) {
      return false;
    }
    final backgroundOnly = switch (action) {
      ComputerUseActionInvoke(:final backgroundOnly) => backgroundOnly,
      ComputerUseActionSetValue(:final backgroundOnly) => backgroundOnly,
      _ => true,
    };
    if (!backgroundOnly) return true;
    final isolation = _computerUseCapabilities!.sessionIsolation;
    return switch (isolation) {
      ComputerUseSessionIsolation.sharedDesktop =>
        capability.backgroundSupport == ComputerUseBackgroundSupport.guarded,
      ComputerUseSessionIsolation.hostIsolated =>
        capability.backgroundSupport == ComputerUseBackgroundSupport.guarded ||
            capability.backgroundSupport ==
                ComputerUseBackgroundSupport.hostIsolatedOnly,
      ComputerUseSessionIsolation.unknown => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final ready =
        !widget.previewMode &&
        (widget.services.chatReady || widget.services.localMode);
    final voiceActive = widget.services.desktopVoiceActive;
    if (voiceActive) return _buildListening(context);

    final currents = widget.services.currents;
    final tasks =
        currents != null && !currents.loading && currents.error == null
        ? currents.items.take(4).toList()
        : const <CurrentCard>[];
    final exchange = _exchangeBuilders();
    final history = _historyBuildersNewestFirst();
    return Stack(
      children: [
        // The scrollbar belongs to the window, not to the reading column:
        // painted inside the 680-wide column it lands on top of the task
        // rows. Suppress the implicit one the list would draw and hang an
        // explicit one off the full-width edge instead. The list itself must
        // span the full viewport too — otherwise the side margins are dead
        // zones that never reach the scrollable.
        Scrollbar(
          controller: _scroll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // The home view fills the viewport apart from a thin
                    // strip at the top, so the tail of the newest message
                    // stays on screen and scrolling up reads as revealing
                    // history rather than as an empty gesture.
                    final greeterExtent = _messages.isEmpty
                        ? constraints.maxHeight
                        : math.max(
                            0.0,
                            constraints.maxHeight - _historyPeekExtent,
                          );
                    return Stack(
                      children: [
                        NotificationListener<ScrollNotification>(
                          onNotification: _handleScroll,
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(
                              context,
                            ).copyWith(scrollbars: false),
                            child: ListView.builder(
                              key: const Key('chat_messages'),
                              controller: _scroll,
                              // Bouncing, not clamping: the pull past
                              // the newest message is the go-home
                              // gesture, so it has to be possible to
                              // overscroll there.
                              physics: const AlwaysScrollableScrollPhysics(
                                parent: BouncingScrollPhysics(),
                              ),
                              reverse: true,
                              // The message directly above the home view is
                              // the peek, so it has to be built even when the
                              // home view is taller than the viewport.
                              scrollCacheExtent: const ScrollCacheExtent.pixels(
                                800,
                              ),
                              itemCount:
                                  history.length +
                                  1 +
                                  (exchange.isEmpty ? 0 : 1),
                              itemBuilder: (context, index) {
                                var slot = index;
                                if (exchange.isNotEmpty) {
                                  if (slot == 0) {
                                    return _buildExchangeSlot(
                                      exchange,
                                      constraints.maxHeight,
                                    );
                                  }
                                  slot -= 1;
                                }
                                if (slot == 0) {
                                  return KeyedSubtree(
                                    key: _homeKey,
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        minHeight: greeterExtent,
                                      ),
                                      child: Center(
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: _readingColumnMaxWidth,
                                          ),
                                          child: _Greeter(
                                            child: _ChatHome(
                                              markState: _sending
                                                  ? OmiOrbState.thinking
                                                  : OmiOrbState.idle,
                                              greeting: _greeting(),
                                              setupTaskDone: _setupTaskDone,
                                              onToggleSetupTask:
                                                  _toggleSetupTask,
                                              starterTasks: _starterTasks,
                                              doneStarterTasks:
                                                  _doneStarterTasks,
                                              onToggleStarterTask:
                                                  _toggleStarterTask,
                                              tasks: tasks,
                                              meetingNotes:
                                                  meetingAssistSupported ||
                                                      widget.previewMode
                                                  ? _meetingNotes
                                                  : const [],
                                              onOpenMeetingNotes:
                                                  _openMeetingNotes,
                                              onComplete: currents == null
                                                  ? null
                                                  : (id) => unawaited(
                                                      currents.dismiss(id),
                                                    ),
                                              onPrompt: _sendPrompt,
                                              onDraftPrompt: _usePrompt,
                                              showByokHint:
                                                  !_byokHintDismissed &&
                                                  _byokPlanFree,
                                              onOpenByok:
                                                  widget.onOpenProviderSettings,
                                              onDismissByok: () =>
                                                  unawaited(_dismissByokHint()),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }
                                return _ReadingColumn(
                                  child: history[slot - 1](),
                                );
                              },
                            ),
                          ),
                        ),
                        if (_messages.isNotEmpty)
                          const Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: 36,
                            child: IgnorePointer(child: _HistoryTopFade()),
                          ),
                        if (_activityMarquee case final label?)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: IgnorePointer(
                              child: _ChatActivityMarquee(label: label),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: _readingColumnMaxWidth,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Reveal(
                        delayMs: 900,
                        child: _ChatInputCard(
                          controller: _input,
                          focusNode: _inputFocus,
                          enabled: ready,
                          busy: _activeRequestId != null,
                          hintText: ready
                              ? _kPlaceholderPrompts[_placeholderIndex]
                              : 'Connect an account and model to start chatting',
                          onSend: _send,
                          onCancel: _cancel,
                          dictation: _dictation,
                        ),
                      ),
                      _buildBottomHint(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildListening(BuildContext context) {
    return Stack(
      key: const Key('chat_listening'),
      fit: StackFit.expand,
      children: [
        const IgnorePointer(child: _VoiceEdgeGradient()),
        InAppVoiceView(
          level: _voiceLevel,
          userTranscript: widget.services.liveVoice.userTranscript,
          assistantTranscript: widget.services.liveVoice.assistantTranscript,
          notice: widget.services.voiceNotice,
          onDone: () =>
              unawaited(handleDesktopGesture(ShiftGestureAction.stopVoice)),
        ),
      ],
    );
  }

  /// The one row allowed to carry the turning mark: the assistant's newest
  /// turn. While a reply is still on its way the skeleton carries it instead,
  /// so the two never spin side by side.
  int get _latestOrbIndex {
    final active = _activeRequestId;
    if (active != null) {
      final streaming = _messages.lastIndexWhere(
        (message) => message.requestId == active && !message.fromUser,
      );
      if (streaming != -1) return streaming;
      return -1;
    }
    return _messages.lastIndexWhere((message) => !message.fromUser);
  }

  /// True once the hub has started streaming an assistant row for [requestId].
  bool _assistantTurnStarted(String requestId) => _messages.any(
    (message) => message.requestId == requestId && !message.fromUser,
  );

  /// Placeholder shimmer only before the first assistant delta arrives.
  bool get _showSkeleton =>
      _activeRequestId != null && !_assistantTurnStarted(_activeRequestId!);

  /// Top status strip while the hub is working but not streaming plain text.
  String? get _activityMarquee {
    final active = _activeRequestId;
    if (active == null) return null;
    final progress = _progress;
    if (progress != null) {
      final parts = progress.split(' · ');
      if (parts.isNotEmpty && parts.first == 'chat_model') {
        if (_assistantTurnStarted(active)) return null;
        final model = _modelFromChatProgress(progress);
        return model == null ? 'Thinking…' : 'Thinking · $model';
      }
      if (_isToolActivityProgress(progress)) {
        return _formatToolActivity(progress);
      }
    }
    if (_assistantTurnStarted(active)) return null;
    return 'Thinking…';
  }

  String? _modelFromChatProgress(String progress) {
    final parts = progress.split(' · ');
    if (parts.length < 3) return null;
    final detail = parts.sublist(2).join(' · ');
    final segments = detail.split(':');
    if (segments.isEmpty) return null;
    final model = segments.last.trim();
    return model.isEmpty ? null : model;
  }

  bool _isToolActivityProgress(String progress) {
    final parts = progress.split(' · ');
    if (parts.length < 2) return false;
    if (parts.first == 'chat_model') return false;
    const terminal = {'complete', 'failed', 'cancelled'};
    return !terminal.contains(parts[1]);
  }

  String _formatToolActivity(String progress) {
    final parts = progress.split(' · ');
    final tool = parts.first;
    final status = parts.length > 1 ? parts[1] : 'running';
    if (parts.length > 2) {
      return '$tool · $status · ${parts.sublist(2).join(' · ')}';
    }
    return '$tool · $status';
  }

  Widget _messageRow(
    _ChatMessage message, {
    required bool latest,
  }) => _BlurFadeIn(
    key: ValueKey(
      'msg_fade_${message.requestId}_${message.fromUser ? 'user' : 'assistant'}',
    ),
    delayMs: _pendingChatReveal ? 220 : 0,
    // The user's own words are bare: the card belongs to the assistant,
    // so the absence of one is what tells the two sides apart.
    child: message.fromUser
        ? Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(48, 12, 12, 12),
              child: Text(
                message.text,
                textAlign: TextAlign.right,
                style: TextStyle(color: _HubColors.of(context).muted),
              ),
            ),
          )
        : _AssistantRow(
            showOrb: latest,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: AssistantContent(
                  message.text,
                  streaming:
                      !message.fromUser &&
                      _activeRequestId != null &&
                      message.requestId == _activeRequestId,
                  onPrompt: _sendPrompt,
                  onDraftPrompt: _usePrompt,
                  palette: _crepusPalette(_HubColors.of(context)),
                ),
              ),
            ),
          ),
  );

  /// Rows for the exchange on screen right now — the message just sent and the
  /// reply forming under it. Empty when the home view owns the viewport.
  List<Widget Function()> _exchangeBuilders() {
    final start = _exchangeStart;
    if (start == null || start >= _messages.length) {
      return const <Widget Function()>[];
    }
    final latest = _latestOrbIndex;
    return <Widget Function()>[
      for (var index = start; index < _messages.length; index++)
        () => _messageRow(_messages[index], latest: index == latest),
      ..._tailBuilders(),
    ];
  }

  List<Widget Function()> _historyBuildersNewestFirst() {
    final end = _exchangeStart ?? _messages.length;
    final latest = _latestOrbIndex;
    final history = <Widget Function()>[
      for (var index = 0; index < end; index++)
        () => KeyedSubtree(
          key: _historyKeys.putIfAbsent(index, GlobalKey.new),
          child: _messageRow(_messages[index], latest: index == latest),
        ),
      // With no live exchange the pending work has nowhere else to go, so it
      // stays at the near end of history, right above the home view.
      if (_exchangeStart == null) ..._tailBuilders(),
    ];
    return history.reversed.toList(growable: false);
  }

  List<Widget Function()> _tailBuilders() {
    return <Widget Function()>[
      for (final proposal in _proposals.values)
        () => Card(
          key: ValueKey('proposal_${proposal.proposalId}'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  proposal.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(proposal.summary),
                const SizedBox(height: 8),
                Text(
                  _riskDetail(proposal.risk),
                  key: ValueKey('risk_${proposal.proposalId}'),
                ),
                if (proposal.targetProvenance case final provenance?) ...[
                  const SizedBox(height: 6),
                  Text(
                    _targetDetail(provenance),
                    key: ValueKey('target_${proposal.proposalId}'),
                  ),
                ] else if (proposal.computerAction != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Fenced target provenance unavailable.',
                    key: ValueKey('target_${proposal.proposalId}'),
                  ),
                ],
                if (proposal.computerAction case final action?) ...[
                  const SizedBox(height: 10),
                  _computerActionDetails(action),
                  const SizedBox(height: 6),
                  Text(
                    _capabilityDetail(action),
                    key: ValueKey('capabilities_${proposal.proposalId}'),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton(
                      key: ValueKey('approve_${proposal.proposalId}'),
                      onPressed: _canApprove(proposal)
                          ? () =>
                                _decide(proposal, ApprovalDecision.approveOnce)
                          : null,
                      child: const Text('Approve once'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      key: ValueKey('reject_${proposal.proposalId}'),
                      onPressed: () =>
                          _decide(proposal, ApprovalDecision.reject),
                      child: const Text('Reject'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      if (_showSkeleton)
        () => _AssistantRow(
          spinning: true,
          child: const _SkeletonBubble(key: Key('chat_skeleton')),
        )
      else if (_progress != null && _activityMarquee == null)
        () => Text(_progress!, key: const Key('chat_progress')),
      if (_error != null)
        () => Text(
          _error!,
          key: const Key('chat_error'),
          style: const TextStyle(color: Colors.redAccent),
        ),
      if (_memorySyncNotice != null)
        () => Text(
          _memorySyncNotice!,
          key: const Key('chat_memory_sync_notice'),
          style: TextStyle(color: Colors.orange.shade300),
        ),
    ];
  }

  /// The live exchange, anchored to the top of the reversed list. Its height
  /// is the whole transition: growing to a viewport lifts the home view out of
  /// sight, and the send animation carries the new message up from below the
  /// fold until it lands under the status strip.
  Widget _buildExchangeSlot(
    List<Widget Function()> exchange,
    double viewportExtent,
  ) => KeyedSubtree(
    key: _exchangeKey,
    child: AnimatedBuilder(
      animation: _sendEnter,
      builder: (context, child) {
        final t = _sendEntered.value;
        if (t >= 1) {
          return ConstrainedBox(
            constraints: BoxConstraints(minHeight: viewportExtent),
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: _exchangeTopInset),
                child: child,
              ),
            ),
          );
        }
        return SizedBox(
          // Never exactly zero: a zero-extent leading item is one the reversed
          // list can decline to build, and the message would pop in mid-rise.
          height: math.max(1, viewportExtent * t),
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: 0,
            maxHeight: double.infinity,
            child: child,
          ),
        );
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _readingColumnMaxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [for (final build in exchange) build()],
        ),
      ),
    ),
  );

  Widget _buildBottomHint() {
    if (_pullProgress > 0) {
      return _NewChatPullProgress(progress: _pullProgress);
    }
    if (_exchangeStart != null) {
      return const _ChatHint(
        text: 'Pull past this message and hold for a new chat',
        icon: Icons.autorenew_rounded,
      );
    }
    if (_messages.isNotEmpty) {
      return const _ChatHint(
        text: 'Earlier messages are above',
        icon: Icons.keyboard_arrow_up_rounded,
      );
    }
    return const SizedBox(height: 26);
  }

  void _openAllTasks(CurrentsController currents) {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => TasksScreen(
            controller: currents,
            checklistStore: _checklist,
            onAccept: (task) {
              Navigator.of(context).maybePop();
              _usePrompt(task.item.proposedNextStep);
            },
          ),
        ),
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    final salutation = hour < 5 || hour >= 22
        ? 'Late night'
        : hour < 12
        ? 'Good morning'
        : hour < 17
        ? 'Good afternoon'
        : 'Good evening';
    final sessionName = widget.previewMode
        ? null
        : widget.services.auth.snapshot.session?.displayName?.trim();
    final displayName = sessionName == null || sessionName.isEmpty
        ? _localName
        : sessionName;
    final name = displayName == null || displayName.trim().isEmpty
        ? null
        : displayName.trim().split(RegExp(r'\s+')).first;
    return name == null ? '$salutation!' : '$salutation, $name!';
  }
}

/// Centers a row inside the hub reading column without shrinking the list
/// item's hit target — the list spans the full viewport width so vertical
/// scroll gestures work in the side margins too.
class _ReadingColumn extends StatelessWidget {
  const _ReadingColumn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _readingColumnMaxWidth),
      child: child,
    ),
  );
}

/// The home view's slot. It is never torn down any more — a send lifts it out
/// of the viewport and scrolling back up brings the same one back — so the
/// entrance fade is all that is left here.
class _Greeter extends StatelessWidget {
  const _Greeter({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: const Key('hub_greeter'),
    child: MediaQuery.disableAnimationsOf(context)
        ? child
        : _BlurFadeIn(key: const Key('hub_greeter_blur_fade'), child: child),
  );
}

class _BlurFadeIn extends StatelessWidget {
  const _BlurFadeIn({this.delayMs = 0, required this.child, super.key});

  final int delayMs;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final total = delayMs + 420;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delayMs / total, 1, curve: Curves.easeOutCubic),
      builder: (context, value, child) {
        if (value >= 1) return child!;
        final sigma = 5 * (1 - value);
        return Opacity(
          opacity: value.clamp(0.0, 1.0),
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: Stack(
              children: [
                child!,
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(
                          0xfff2c2ac,
                        ).withValues(alpha: .10 * (1 - value)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      child: child,
    );
  }
}

class _CompletionFade extends StatefulWidget {
  const _CompletionFade({required this.done, required this.child});

  final bool done;
  final Widget child;

  @override
  State<_CompletionFade> createState() => _CompletionFadeState();
}

class _CompletionFadeState extends State<_CompletionFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void didUpdateWidget(covariant _CompletionFade old) {
    super.didUpdateWidget(old);
    if (!old.done && widget.done && !MediaQuery.disableAnimationsOf(context)) {
      _fade.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _fade,
    child: widget.child,
    builder: (context, child) {
      final value = _fade.value;
      if (!_fade.isAnimating || value <= 0 || value >= 1) return child!;
      final eased = Curves.easeOutCubic.transform(value);
      final sigma = 2.5 * (1 - eased);
      return Stack(
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: child,
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                key: const Key('task_complete_fade'),
                decoration: BoxDecoration(
                  color: const Color(
                    0xfff2c2ac,
                  ).withValues(alpha: .18 * (1 - eased)),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// One quiet line under the composer teaching the gesture that applies right
/// now. Never two at once: a stack of tips reads as a manual, not as a hint.
class _ChatHint extends StatelessWidget {
  const _ChatHint({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = _HubColors.of(context);
    return SizedBox(
      height: 26,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          key: const Key('chat_hint'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: colors.muted),
            const SizedBox(width: 4),
            Text(text, style: TextStyle(fontSize: 11.5, color: colors.muted)),
          ],
        ),
      ),
    );
  }
}

/// How much of the hold is done. Without it the threshold is invisible and the
/// gesture is a guess about how long is long enough.
class _NewChatPullProgress extends StatelessWidget {
  const _NewChatPullProgress({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final colors = _HubColors.of(context);
    return SizedBox(
      height: 26,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, left: 24, right: 24),
        child: Align(
          alignment: Alignment.topCenter,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              key: const Key('chat_new_chat_progress'),
              height: 3,
              child: Stack(
                children: [
                  Positioned.fill(child: ColoredBox(color: colors.hairline)),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress.clamp(0.0, 1.0),
                    child: ColoredBox(color: colors.ink),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryTopFade extends StatelessWidget {
  const _HistoryTopFade();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final page = dark
        ? const Color(0xff1c1c1a)
        : omiDemoMode
        ? Colors.transparent
        : const Color(0xfff7f6f1);
    return DecoratedBox(
      key: const Key('history_top_fade'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [page, page.withValues(alpha: 0)],
        ),
      ),
    );
  }
}

/// A pill at the top of the chat viewport reporting what Omi is doing while a
/// turn is in flight — model routing, tool work, memory — but not during plain
/// text generation, which streams in the assistant bubble instead.
class _ChatActivityMarquee extends StatelessWidget {
  const _ChatActivityMarquee({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = _HubColors.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _readingColumnMaxWidth),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.cardBg.withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: colors.hairline),
                boxShadow: [
                  BoxShadow(
                    color: colors.cardShadow,
                    offset: const Offset(0, 2),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                child: _MarqueeLabel(
                  key: const Key('chat_activity_marquee'),
                  label: label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: colors.muted,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MarqueeLabel extends StatefulWidget {
  const _MarqueeLabel({required this.label, required this.style, super.key});

  final String label;
  final TextStyle style;

  @override
  State<_MarqueeLabel> createState() => _MarqueeLabelState();
}

class _MarqueeLabelState extends State<_MarqueeLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scroll;
  double _overflow = 0;

  @override
  void initState() {
    super.initState();
    _scroll = AnimationController(vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(covariant _MarqueeLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.label != widget.label) {
      _scroll.stop();
      _scroll.reset();
      _overflow = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _measure() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final textPainter = TextPainter(
      text: TextSpan(text: widget.label, style: widget.style),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout(maxWidth: double.infinity);
    final viewport = box.size.width;
    final overflow = math.max(0.0, textPainter.width - viewport);
    if ((overflow - _overflow).abs() < 1) return;
    setState(() => _overflow = overflow);
    _scroll.stop();
    if (overflow <= 0 ||
        MediaQuery.maybeOf(context)?.disableAnimations == true) {
      return;
    }
    _scroll.duration = Duration(
      milliseconds: (6000 + overflow * 18).round().clamp(6000, 18000),
    );
    _scroll.repeat();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
        final label = Text(
          widget.label,
          maxLines: 1,
          softWrap: false,
          style: widget.style,
        );
        if (_overflow <= 0 ||
            MediaQuery.maybeOf(context)?.disableAnimations == true) {
          return Align(alignment: Alignment.center, child: label);
        }
        return ClipRect(
          child: AnimatedBuilder(
            animation: _scroll,
            builder: (context, _) => Transform.translate(
              offset: Offset(-_overflow * _scroll.value, 0),
              child: label,
            ),
          ),
        );
      },
    );
  }
}

class _VoiceEdgeGradient extends StatelessWidget {
  const _VoiceEdgeGradient();

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: const [
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-1.15, -1.1),
            radius: .9,
            colors: [Color(0x55a85e46), Color(0x00a85e46)],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(1.15, -.9),
            radius: .9,
            colors: [Color(0x554e687c), Color(0x004e687c)],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(.9, 1.15),
            radius: .9,
            colors: [Color(0x55a6aa79), Color(0x00a6aa79)],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-1.1, 1.05),
            radius: .9,
            colors: [Color(0x55c78067), Color(0x00c78067)],
          ),
        ),
      ),
    ],
  );
}

class _ChatHome extends StatelessWidget {
  const _ChatHome({
    required this.greeting,
    required this.setupTaskDone,
    required this.onToggleSetupTask,
    required this.starterTasks,
    required this.doneStarterTasks,
    required this.onToggleStarterTask,
    required this.tasks,
    required this.meetingNotes,
    required this.onOpenMeetingNotes,
    required this.onComplete,
    required this.onPrompt,
    required this.onDraftPrompt,
    this.showByokHint = false,
    this.onOpenByok,
    this.onDismissByok,
    this.markState = OmiOrbState.idle,
  });

  /// What the mark should be expressing. The greeter is the most-looked-at
  /// mark in the app, so it should say what Omi is actually doing rather than
  /// idling through a showcase while a reply is streaming in.
  final OmiOrbState markState;

  final String greeting;
  final bool setupTaskDone;
  final VoidCallback onToggleSetupTask;
  final List<String> starterTasks;
  final Set<String> doneStarterTasks;
  final ValueChanged<String> onToggleStarterTask;
  final List<CurrentCard> tasks;
  final List<MeetingNote> meetingNotes;
  final VoidCallback onOpenMeetingNotes;
  final ValueChanged<String>? onComplete;
  final ValueChanged<String> onPrompt;

  /// Drafts text into the composer without sending it, so model-authored
  /// `prompt:` actions are seen before they are submitted.
  final ValueChanged<String> onDraftPrompt;
  final bool showByokHint;
  final VoidCallback? onOpenByok;
  final VoidCallback? onDismissByok;

  @override
  Widget build(BuildContext context) {
    final colors = _HubColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Reveal(
            delayMs: 0,
            child: Column(
              children: [
                OmiIdleShowcase(size: 48, state: markState),
                const SizedBox(height: 16),
                Text(
                  greeting,
                  key: const Key('hub_greeting'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Literata',
                    fontSize: 44,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -1.98,
                    color: colors.ink,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 36),
          // No "what matters next" heading and no "all tasks" link: this
          // section already IS what matters next, and anyone who wants the
          // full list can just ask the agent for it.
          _Reveal(
            delayMs: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (tasks.isNotEmpty)
                  _CurrentFocus(
                    cards: tasks,
                    onDraftPrompt: onDraftPrompt,
                    onComplete: onComplete,
                  ),
                _TaskRow(
                  key: const Key('task_setup_omi'),
                  title: 'Set up Omi.',
                  done: setupTaskDone,
                  completeKey: const Key('complete_setup_omi'),
                  onComplete: onToggleSetupTask,
                  onTap: onToggleSetupTask,
                ),
                for (final title in starterTasks)
                  if (HubTaskMeta.tryDecode(title) case final meta?)
                    _RichTaskRow(
                      key: ValueKey('starter_task_$title'),
                      meta: meta,
                      done: doneStarterTasks.contains(title),
                      completeKey: ValueKey('complete_starter_$title'),
                      onComplete: () => onToggleStarterTask(title),
                      onTap: () => onPrompt(meta.title),
                    )
                  else
                    _TaskRow(
                      key: ValueKey('starter_task_$title'),
                      title: title,
                      done: doneStarterTasks.contains(title),
                      completeKey: ValueKey('complete_starter_$title'),
                      onComplete: () => onToggleStarterTask(title),
                      onTap: () => onPrompt(title),
                    ),
                for (final note in meetingNotes.take(3))
                  _MeetingNoteRow(
                    key: ValueKey('meeting_note_${note.id}'),
                    note: note,
                    onTap: onOpenMeetingNotes,
                  ),
                if (meetingNotes.length > 3)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: colors.hairline)),
                    ),
                    child: InkWell(
                      key: const Key('hub_all_meeting_notes'),
                      onTap: onOpenMeetingNotes,
                      hoverColor: colors.rowHover,
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          'All meeting notes →',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colors.muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (showByokHint)
                  _ByokHintRow(onOpen: onOpenByok, onDismiss: onDismissByok),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrentFocus extends StatefulWidget {
  const _CurrentFocus({
    required this.cards,
    required this.onDraftPrompt,
    required this.onComplete,
  });

  final List<CurrentCard> cards;
  final ValueChanged<String> onDraftPrompt;
  final ValueChanged<String>? onComplete;

  @override
  State<_CurrentFocus> createState() => _CurrentFocusState();
}

class _CurrentFocusState extends State<_CurrentFocus> {
  @override
  Widget build(BuildContext context) {
    final plan = planBrief(
      widget.cards,
      now: DateTime.now(),
      maxRest: widget.cards.length,
    );
    final hero = plan.hero;
    if (hero == null) return const SizedBox.shrink();
    final colors = _HubColors.of(context);
    final card = hero.card;
    final evidence = card.item.evidence;
    final source = (card.sourceKind ?? 'Current').toUpperCase();
    final surface = Color.alphaBlend(
      colors.hintBlue.withValues(alpha: .08),
      colors.cardBg,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        key: const Key('current_focus'),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: colors.hairline),
          boxShadow: [
            BoxShadow(
              color: colors.cardShadow,
              offset: const Offset(0, 10),
              blurRadius: 28,
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              top: -72,
              right: -52,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        colors.hintBlue.withValues(alpha: .24),
                        colors.hintBlue.withValues(alpha: 0),
                      ],
                    ),
                  ),
                  child: const SizedBox(width: 220, height: 220),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 30,
                        height: 30,
                        child: OmiActivityOrb(
                          size: 22,
                          state: OmiOrbState.thinking,
                          period: const Duration(seconds: 7),
                          color: colors.hintBlue,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'CURRENT',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                          color: colors.muted,
                        ),
                      ),
                      const Spacer(),
                      _CurrentChip(label: source, color: colors.hintBlue),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    card.title,
                    key: const Key('current_focus_title'),
                    style: TextStyle(
                      fontFamily: 'Literata',
                      fontSize: 24,
                      height: 1.08,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -1,
                      color: colors.ink,
                    ),
                  ),
                  if (card.summary.trim().isNotEmpty) ...[
                    const SizedBox(height: 9),
                    Text(
                      card.summary,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: colors.muted,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _CurrentDetail(
                    label: 'WHY NOW',
                    text: card.item.reason,
                    color: colors,
                    detailKey: const Key('current_focus_reason'),
                  ),
                  const SizedBox(height: 12),
                  _CurrentDetail(
                    label: 'EVIDENCE',
                    text: evidence
                        .map((item) => '${item.sourceId}: ${item.reason}')
                        .join(' · '),
                    color: colors,
                    detailKey: const Key('current_focus_evidence'),
                  ),
                  const SizedBox(height: 16),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.hintBlue.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'NEXT ACTION',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                              color: colors.muted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            card.item.proposedNextStep,
                            key: const Key('current_focus_next_action'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.32,
                              fontWeight: FontWeight.w600,
                              color: colors.ink,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              TextButton(
                                key: const Key('current_focus_act'),
                                onPressed: () => widget.onDraftPrompt(
                                  card.item.proposedNextStep,
                                ),
                                style: TextButton.styleFrom(
                                  foregroundColor: colors.hintBlue,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 6,
                                  ),
                                  textStyle: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                child: const Text('Work on this →'),
                              ),
                              if (widget.onComplete != null) ...[
                                const SizedBox(width: 8),
                                TextButton(
                                  key: const Key('current_focus_done'),
                                  onPressed: () =>
                                      widget.onComplete!(card.item.id),
                                  style: TextButton.styleFrom(
                                    foregroundColor: colors.muted,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 6,
                                    ),
                                    textStyle: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  child: const Text('Done'),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentDetail extends StatelessWidget {
  const _CurrentDetail({
    required this.label,
    required this.text,
    required this.color,
    required this.detailKey,
  });

  final String label;
  final String text;
  final _HubColors color;
  final Key detailKey;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(left: BorderSide(color: color.hairline)),
    ),
    child: Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: color.muted,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            text,
            key: detailKey,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, height: 1.35, color: color.ink),
          ),
        ],
      ),
    ),
  );
}

class _CurrentChip extends StatelessWidget {
  const _CurrentChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.w800,
          letterSpacing: .9,
          color: color,
        ),
      ),
    ),
  );
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.title,
    required this.done,
    required this.completeKey,
    required this.onComplete,
    required this.onTap,
    super.key,
  });

  final String title;
  final bool done;
  final Key completeKey;
  final VoidCallback? onComplete;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = _HubColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.hairline)),
      ),
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.rowHover,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: _CompletionFade(
          done: done,
          child: Opacity(
            opacity: done ? .45 : 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                children: [
                  InkWell(
                    key: completeKey,
                    onTap: onComplete,
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 16,
                      height: 16,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.muted),
                      ),
                      child: done
                          ? Text(
                              '✓',
                              style: TextStyle(fontSize: 10, color: colors.ink),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colors.ink,
                        decoration: done
                            ? TextDecoration.lineThrough
                            : TextDecoration.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

CrepusCurrentPalette _crepusPalette(_HubColors colors) => CrepusCurrentPalette(
  ink: colors.ink,
  muted: colors.muted,
  hairline: colors.hairline,
  cardBg: colors.cardBg,
  cardShadow: colors.cardShadow,
  accent: colors.hintBlue,
  rowHover: colors.rowHover,
);

class _RichTaskRow extends StatelessWidget {
  const _RichTaskRow({
    required this.meta,
    required this.done,
    required this.completeKey,
    required this.onComplete,
    required this.onTap,
    super.key,
  });

  final HubTaskMeta meta;
  final bool done;
  final Key completeKey;
  final VoidCallback? onComplete;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = _HubColors.of(context);
    final time = meta.formatTimeRange();
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.hairline)),
      ),
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.rowHover,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: _CompletionFade(
          done: done,
          child: Opacity(
            opacity: done ? .45 : 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: InkWell(
                      key: completeKey,
                      onTap: onComplete,
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 16,
                        height: 16,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: colors.muted),
                        ),
                        child: done
                            ? Text(
                                '✓',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.ink,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: DecoratedBox(
                      key: ValueKey('rich_task_card_${meta.title}'),
                      decoration: BoxDecoration(
                        color: colors.cardBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: colors.hairline),
                        boxShadow: [
                          BoxShadow(
                            color: colors.cardShadow,
                            offset: const Offset(0, 4),
                            blurRadius: 16,
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 3,
                              height: 34,
                              margin: const EdgeInsets.only(right: 10, top: 2),
                              decoration: BoxDecoration(
                                color: colors.hintBlue,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    meta.title,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: colors.ink,
                                      decoration: done
                                          ? TextDecoration.lineThrough
                                          : TextDecoration.none,
                                    ),
                                  ),
                                  if (time != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        time,
                                        key: ValueKey(
                                          'rich_task_time_${meta.title}',
                                        ),
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: colors.muted,
                                        ),
                                      ),
                                    ),
                                  if (meta.detail case final detail?)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        detail,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 18 / 12,
                                          color: colors.muted,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The assistant's turn: the omi mark as its profile picture, left of the
/// bubble. [spinning] lights the mark with the site pulse while a reply is
/// still coming. [showOrb] is false on older turns — a column of marks all
/// pulsing at once reads as several things happening, when only the newest
/// turn is live.
class _AssistantRow extends StatelessWidget {
  const _AssistantRow({
    required this.child,
    this.spinning = false,
    this.showOrb = true,
  });

  final Widget child;
  final bool spinning;
  final bool showOrb;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 4, right: 10),
        child: showOrb
            ? (spinning
                  ? const OmiActivityOrb.loading(
                      size: 26,
                      key: Key('chat_latest_orb'),
                    )
                  : const OmiActivityOrb(size: 26, key: Key('chat_latest_orb')))
            : const SizedBox.square(dimension: 26),
      ),
      Flexible(child: child),
    ],
  );
}

/// The placeholder shown while the assistant's reply is still streaming in —
/// three pulsing dots so the wait reads as thinking rather than a stall. The
/// animated mark beside it carries the brand identity; the dots are the rhythm.
class _SkeletonBubble extends StatefulWidget {
  const _SkeletonBubble({super.key});

  @override
  State<_SkeletonBubble> createState() => _SkeletonBubbleState();
}

class _SkeletonBubbleState extends State<_SkeletonBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (debugOmiOrbStatic ||
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false)) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = _HubColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _ThinkingDots(animation: _pulse, color: colors.muted),
      ),
    );
  }
}

/// Three staggered dots that breathe in and out — the classic typing rhythm.
class _ThinkingDots extends StatelessWidget {
  const _ThinkingDots({required this.animation, required this.color});

  final Animation<double> animation;
  final Color color;

  static const _dotSize = 7.0;
  static const _gap = 6.0;
  static const _stagger = 0.22;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : _gap),
            child: _ThinkingDot(
              t: animation.value,
              phase: i * _stagger,
              color: color,
            ),
          ),
      ],
    ),
  );
}

class _ThinkingDot extends StatelessWidget {
  const _ThinkingDot({
    required this.t,
    required this.phase,
    required this.color,
  });

  final double t;
  final double phase;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final wave = (t + phase) % 1.0;
    final scale =
        0.55 +
        0.45 *
            Curves.easeInOut.transform(wave < 0.5 ? wave * 2 : (1 - wave) * 2);
    final alpha = 0.35 + 0.65 * scale;
    return Transform.scale(
      scale: scale,
      child: Container(
        width: _ThinkingDots._dotSize,
        height: _ThinkingDots._dotSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: alpha),
        ),
      ),
    );
  }
}

/// A completed meeting, rendered as a current so the notes Omi wrote sit
/// alongside "what matters next" instead of behind a settings screen. The
/// whole row opens the notes; there is no completion circle — a meeting that
/// happened is not a task to tick off.
class _MeetingNoteRow extends StatelessWidget {
  const _MeetingNoteRow({required this.note, required this.onTap, super.key});

  final MeetingNote note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = _HubColors.of(context);
    final points = note.keyPoints;
    final preview = points.isNotEmpty ? points.first : note.summary;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.hairline)),
      ),
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.rowHover,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.sticky_note_2_outlined,
                  size: 16,
                  color: colors.muted,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                key: ValueKey('meeting_note_card_${note.id}'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            note.title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: colors.ink,
                            ),
                          ),
                        ),
                        Text(
                          note.meetingTypeLabel.toUpperCase(),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.17,
                            color: colors.muted,
                          ),
                        ),
                      ],
                    ),
                    if (preview.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 18 / 12,
                            color: colors.muted,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The BYOK nudge under the task list. The whole row opens settings at the
/// provider-keys section, and the close control retires it for good — a hint
/// that cannot be acted on or put away is just noise.
class _ByokHintRow extends StatelessWidget {
  const _ByokHintRow({required this.onOpen, required this.onDismiss});

  final VoidCallback? onOpen;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = _HubColors.of(context);
    return DecoratedBox(
      key: const Key('hub_byok_hint'),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colors.hairline),
          bottom: BorderSide(color: colors.hairline),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: InkWell(
              key: const Key('hub_byok_hint_open'),
              onTap: onOpen,
              hoverColor: colors.rowHover,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '↳',
                        style: TextStyle(fontSize: 14, color: colors.hintBlue),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        'By the way, if you bring your own keys or sign in with '
                        "your own AI subscription, Omi's price is negotiable.",
                        style: TextStyle(
                          fontSize: 12,
                          height: 20 / 12,
                          color: colors.hintBlue,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: IconButton(
              key: const Key('hub_byok_hint_dismiss'),
              tooltip: 'Hide this tip',
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
              icon: Icon(Icons.close_rounded, color: colors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatInputCard extends StatefulWidget {
  const _ChatInputCard({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.busy,
    required this.hintText,
    required this.onSend,
    required this.onCancel,
    this.dictation,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool busy;
  final String hintText;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  /// Dictation for the composer. Null when nothing can transcribe, which the
  /// microphone shows as an explained state rather than hiding itself.
  final ComposerDictation? dictation;

  @override
  State<_ChatInputCard> createState() => _ChatInputCardState();
}

class _ChatInputCardState extends State<_ChatInputCard> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_focusChanged);
    widget.controller.addListener(_focusChanged);
    widget.dictation?.addListener(_focusChanged);
    widget.dictation?.partialTranscript.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(covariant _ChatInputCard old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_focusChanged);
      widget.focusNode.addListener(_focusChanged);
    }
    if (old.controller != widget.controller) {
      old.controller.removeListener(_focusChanged);
      widget.controller.addListener(_focusChanged);
    }
    if (old.dictation != widget.dictation) {
      old.dictation?.removeListener(_focusChanged);
      old.dictation?.partialTranscript.removeListener(_focusChanged);
      widget.dictation?.addListener(_focusChanged);
      widget.dictation?.partialTranscript.addListener(_focusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    widget.controller.removeListener(_focusChanged);
    widget.dictation?.removeListener(_focusChanged);
    widget.dictation?.partialTranscript.removeListener(_focusChanged);
    super.dispose();
  }

  /// Records, then puts the transcript in the composer at the caret. The
  /// message is never sent: dictation is a way of typing, not of submitting.
  Future<void> _toggleDictation() async {
    final dictation = widget.dictation;
    if (dictation == null) return;
    if (dictation.state == DictationState.recording) {
      final text = await dictation.stop();
      if (text == null || !mounted) return;
      final controller = widget.controller;
      final existing = controller.text;
      final joined = existing.isEmpty ? text : '${existing.trimRight()} $text';
      controller.value = TextEditingValue(
        text: joined,
        selection: TextSelection.collapsed(offset: joined.length),
      );
      widget.focusNode.requestFocus();
      return;
    }
    if (dictation.state != DictationState.idle) {
      dictation.acknowledge();
      return;
    }
    await dictation.start();
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = _HubColors.of(context);
    final focused = widget.focusNode.hasFocus;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    return AnimatedContainer(
      duration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: focused ? colors.focusRing : colors.hairline),
        boxShadow: [
          BoxShadow(
            color: colors.cardShadow,
            offset: Offset(0, focused ? 10 : 14),
            blurRadius: focused ? 34 : 44,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 13, 13, 13),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildRow(colors),
                  if (widget.dictation?.message != null)
                    _buildDictationNotice(colors, widget.dictation!.message!),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A refused permission or an unavailable model is said out loud in the
  /// composer, so the microphone is never a control that silently does nothing.
  Widget _buildDictationNotice(_HubColors colors, String message) => Padding(
    key: const Key('dictation_notice'),
    padding: const EdgeInsets.only(left: 0, right: 7, top: 8),
    child: Text(message, style: TextStyle(fontSize: 12, color: colors.muted)),
  );

  Widget _buildRow(_HubColors colors) {
    final dictation = widget.dictation;
    final recording = dictation?.state == DictationState.recording;
    final transcribing = dictation?.state == DictationState.transcribing;
    final dictationBusy = recording || transcribing;
    return Row(
      children: [
        Expanded(
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              if (widget.controller.text.isEmpty && dictationBusy)
                IgnorePointer(
                  child: recording
                      ? _ComposerRecordingWaveform(
                          key: const Key('composer_dictation_waveform'),
                          level: dictation!.level,
                          color: colors.muted,
                        )
                      : ValueListenableBuilder<String>(
                          valueListenable: dictation!.partialTranscript,
                          builder: (context, partial, _) => Text(
                            partial.isNotEmpty ? partial : 'Transcribing…',
                            key: const Key('composer_dictation_caption'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              color: colors.muted,
                              fontStyle: partial.isEmpty
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                            ),
                          ),
                        ),
                )
              else if (widget.controller.text.isEmpty)
                IgnorePointer(
                  child: _AnimatedPlaceholder(
                    text: widget.hintText,
                    style: TextStyle(fontSize: 15, color: colors.muted),
                  ),
                ),
              TextField(
                key: const Key('chat_input'),
                controller: widget.controller,
                focusNode: widget.focusNode,
                enabled: widget.enabled,
                readOnly: widget.busy || dictationBusy,
                onSubmitted: (_) => widget.onSend(),
                style: TextStyle(fontSize: 15, color: colors.ink),
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: widget.hintText,
                  hintStyle: const TextStyle(
                    fontSize: 15,
                    color: Colors.transparent,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (widget.dictation != null) ...[
          const SizedBox(width: 4),
          _DictationButton(
            dictation: widget.dictation!,
            enabled: widget.enabled && !widget.busy,
            onPressed: () => unawaited(_toggleDictation()),
            colors: colors,
          ),
        ],
        const SizedBox(width: 12),
        SizedBox(
          width: 38,
          height: 38,
          child: widget.busy
              ? IconButton(
                  key: const Key('cancel_chat'),
                  onPressed: widget.onCancel,
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    backgroundColor: colors.sendBg,
                    foregroundColor: colors.sendFg,
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.stop_rounded, size: 18),
                )
              : IconButton(
                  key: const Key('send_chat'),
                  onPressed: widget.enabled ? widget.onSend : null,
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    backgroundColor: colors.sendBg,
                    foregroundColor: colors.sendFg,
                    disabledBackgroundColor: colors.sendDisabledBg,
                    disabledForegroundColor: colors.sendFg,
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                ),
        ),
      ],
    );
  }
}

/// A wide bar waveform in the composer placeholder while dictation is live.
class _ComposerRecordingWaveform extends StatefulWidget {
  const _ComposerRecordingWaveform({
    required this.level,
    required this.color,
    super.key,
  });

  final ValueListenable<double> level;
  final Color color;

  @override
  State<_ComposerRecordingWaveform> createState() =>
      _ComposerRecordingWaveformState();
}

class _ComposerRecordingWaveformState extends State<_ComposerRecordingWaveform>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  double _phase = 0;
  double _eased = 0;

  bool get _animated => !MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_levelChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_animated) {
      _ticker ??= createTicker(_tick)..start();
    } else {
      _ticker?.dispose();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    widget.level.removeListener(_levelChanged);
    _ticker?.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    setState(() {
      _phase = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
      final target = widget.level.value.clamp(0.0, 1.0);
      _eased = target > _eased
          ? _eased + (target - _eased) * 0.55
          : _eased + (target - _eased) * 0.12;
    });
  }

  void _levelChanged() {
    if (_ticker == null && mounted) {
      setState(() => _eased = widget.level.value.clamp(0.0, 1.0));
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 28,
    width: double.infinity,
    child: CustomPaint(
      painter: InAppVoiceWaveformPainter(
        level: _eased,
        phase: _animated ? _phase : null,
        color: widget.color,
      ),
    ),
  );
}

/// The composer's microphone. Press to record, press again to stop, and the
/// transcript lands in the field to be edited — it never sends.
class _DictationButton extends StatelessWidget {
  const _DictationButton({
    required this.dictation,
    required this.enabled,
    required this.onPressed,
    required this.colors,
  });

  final ComposerDictation dictation;
  final bool enabled;
  final VoidCallback onPressed;
  final _HubColors colors;

  @override
  Widget build(BuildContext context) {
    final state = dictation.state;
    final recording = state == DictationState.recording;
    final transcribing = state == DictationState.transcribing;
    // The mark is the recording state: the same orb the rest of the app uses,
    // swelling with the input level. It honours reduced motion itself.
    if (recording || transcribing) {
      return SizedBox(
        width: 38,
        height: 38,
        child: IconButton(
          key: const Key('stop_dictation'),
          tooltip: recording ? 'Stop recording' : 'Transcribing',
          onPressed: recording ? onPressed : null,
          padding: EdgeInsets.zero,
          icon: ValueListenableBuilder<double>(
            valueListenable: dictation.level,
            builder: (context, level, child) => OmiActivityOrb(
              size: 22,
              state: recording ? OmiOrbState.listening : OmiOrbState.thinking,
              period: recording
                  ? const Duration(seconds: 8)
                  : const Duration(milliseconds: 1700),
              amplitude: level,
              color: colors.ink,
            ),
          ),
        ),
      );
    }
    final blocked =
        state == DictationState.denied || state == DictationState.unavailable;
    return SizedBox(
      width: 38,
      height: 38,
      child: IconButton(
        key: const Key('start_dictation'),
        tooltip: blocked ? dictation.message : 'Dictate a message',
        onPressed: enabled || blocked ? onPressed : null,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          foregroundColor: blocked ? colors.muted : colors.ink,
          disabledForegroundColor: colors.muted,
          shape: const CircleBorder(),
        ),
        icon: Icon(
          blocked ? Icons.mic_off_rounded : Icons.mic_none_rounded,
          size: 20,
        ),
      ),
    );
  }
}

class _AnimatedPlaceholder extends StatefulWidget {
  const _AnimatedPlaceholder({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_AnimatedPlaceholder> createState() => _AnimatedPlaceholderState();
}

class _AnimatedPlaceholderState extends State<_AnimatedPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _swap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
  )..addListener(_tick);
  late String _shown = widget.text;

  void _tick() {
    if (!mounted) return;
    setState(() {
      if (_swap.value >= .5 && _shown != widget.text) _shown = widget.text;
    });
  }

  @override
  void didUpdateWidget(covariant _AnimatedPlaceholder old) {
    super.didUpdateWidget(old);
    if (widget.text == _shown) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _shown = widget.text;
      return;
    }
    _swap.forward(from: 0);
  }

  @override
  void dispose() {
    _swap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double opacity = 1;
    double dy = 0;
    double sigma = 0;
    Color? color = widget.style.color;
    if (_swap.isAnimating) {
      final value = _swap.value;
      if (value < .5) {
        final t = Curves.easeInCubic.transform(value * 2);
        opacity = 1 - t;
        dy = -4 * t;
        sigma = 3 * t;
      } else {
        final t = Curves.easeOutCubic.transform((value - .5) * 2);
        opacity = t;
        dy = 5 * (1 - t);
        sigma = 3 * (1 - t);
        color = Color.lerp(const Color(0xffd99a72), color, t);
      }
    }
    final text = Text(
      _shown,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style.copyWith(color: color),
    );
    return KeyedSubtree(
      key: const Key('chat_placeholder'),
      child: Transform.translate(
        offset: Offset(0, dy),
        child: Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: sigma <= 0
              ? text
              : ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                  child: text,
                ),
        ),
      ),
    );
  }
}

class _Reveal extends StatelessWidget {
  const _Reveal({required this.delayMs, required this.child});

  final int delayMs;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final total = delayMs + 650;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delayMs / total, 1, curve: const Cubic(.22, 1, .36, 1)),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

final class _ChatMessage {
  const _ChatMessage({
    required this.requestId,
    required this.text,
    required this.fromUser,
  });

  final String requestId;
  final String text;
  final bool fromUser;
}
