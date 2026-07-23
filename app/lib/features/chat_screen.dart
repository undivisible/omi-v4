import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/worker_http.dart'
    show BillingEntitlement, OmiPlan, WorkerAuthenticationException;
import '../app_services.dart';
import '../channels/channels.dart';
import '../currents/crepus_current.dart';
import '../currents/currents.dart';
import '../keyboard/keyboard.dart';
import '../keyboard/shake_gesture.dart';
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
import '../ui/markdown_text.dart';
import '../ui/omi_ui.dart';
import 'cursor_pill_controller.dart' show CombinedVoiceLevel;
import 'hub_task_meta.dart';
import 'in_app_voice_view.dart';
import 'meeting_notes.dart';
import 'meeting_notes_screen.dart';
import 'tasks_screen.dart';

/// Height of the sliver of conversation left visible above the home view, so
/// the newest message peeks in and scrolling up is discoverable.
const double _historyPeekExtent = 44;

/// Reads the plan this account is on. Null means there is nothing to ask —
/// no billing backend — which is itself a free setup.
typedef EntitlementProbe = Future<BillingEntitlement?> Function();

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.services,
    this.previewMode = false,
    this.desktopKeyboard,
    this.onDesktopGestureReset,
    this.onShakeSummon,
    this.checklistStore,
    this.onOpenProviderSettings,
    this.entitlementProbe,
    super.key,
  });

  final AppServices services;
  final bool previewMode;
  final DesktopKeyboard? desktopKeyboard;
  final VoidCallback? onDesktopGestureReset;

  /// When set, a completed cursor shake summons voice through this callback
  /// (the full-screen pill overlay) instead of the in-window listening view.
  final Future<void> Function()? onShakeSummon;

  final HubChecklistStore? checklistStore;

  /// Opens settings at the BYOK/provider-keys section, for the hint row under
  /// the task list.
  final VoidCallback? onOpenProviderSettings;

  /// Override for the plan lookup that gates the BYOK hint.
  final EntitlementProbe? entitlementProbe;

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
        muted: const Color(0xff8d8980),
        hairline: const Color(0x1a000000),
        hintBlue: const Color(0xff3139fb),
        cardBg: Colors.white,
        cardShadow: const Color(0x0a000000),
        sendBg: const Color(0xff171716),
        sendFg: Colors.white,
        sendDisabledBg: const Color(0x33171716),
        rowHover: const Color(0x8cffffff),
        focusRing: const Color(0x40171716),
      );

  const _HubColors.dark()
    : this._(
        ink: const Color(0xfff4f2ea),
        muted: const Color(0xffa6a49c),
        hairline: const Color(0x1affffff),
        hintBlue: const Color(0xff9aa0ff),
        cardBg: const Color(0xff232321),
        cardShadow: const Color(0x33000000),
        sendBg: const Color(0xfffffcec),
        sendFg: const Color(0xff171716),
        sendDisabledBg: const Color(0x33fffcec),
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

class ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
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
  ComputerUseCapabilities? _computerUseCapabilities;
  bool _sending = false;
  int _conversationLoadGeneration = 0;
  int _conversationCursor = 0;
  Timer? _shakeDecayTimer;
  double? _lastShakeX;
  Offset _lastShakePosition = Offset.zero;
  int _lastShakeDirection = 0;
  DateTime _lastShakeReversalAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _shakeProgress = 0;
  bool _activatingShakeVoice = false;
  late final HubChecklistStore _checklist =
      widget.checklistStore ?? PreferencesHubChecklistStore();
  static const byokHintDismissedKey = 'hub_byok_hint_dismissed_v1';
  late final EntitlementProbe _entitlementProbe =
      widget.entitlementProbe ??
      () async => widget.previewMode
          ? null
          : await widget.services.billing?.getEntitlement();
  bool _byokHintDismissed = true;
  bool _byokPlanFree = false;
  bool _setupTaskDone = true;
  bool _greeterDismissed = false;
  final _scroll = ScrollController();
  final _greeterKey = GlobalKey();
  bool _snapping = false;
  bool _pendingChatReveal = false;
  Timer? _chatRevealTimer;
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
    _shakeDecayTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted || _shakeProgress <= 0) return;
      setState(() => _shakeProgress = (_shakeProgress - 8).clamp(0, 100));
    });
    if (!widget.previewMode) {
      widget.services.currents?.addListener(_currentsChanged);
      unawaited(_refreshCurrents());
      unawaited(_loadConversation());
      _events = widget.services.nativeEvents.listen(_handleEvent);
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
    if (currents == null || !widget.services.chatReady) return;
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
          await widget.services.startDesktopVoice();
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
            _progress = submission == null ? null : 'Thinking';
            if (submission != null) {
              _dismissGreeter();
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
    } catch (failure) {
      if (mounted && generation == _conversationLoadGeneration) {
        setState(() => _error = _describeError(failure));
      }
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

  @override
  void dispose() {
    _conversationLoadGeneration += 1;
    _conversationRefreshTimer?.cancel();
    widget.services.currents?.removeListener(_currentsChanged);
    widget.onDesktopGestureReset?.call();
    unawaited(widget.services.cancelDesktopVoice());
    unawaited(_events?.cancel());
    unawaited(_authorityChanges?.cancel());
    for (final timer in _proposalExpiryTimers.values) {
      timer.cancel();
    }
    _placeholderTimer?.cancel();
    _shakeDecayTimer?.cancel();
    _chatRevealTimer?.cancel();
    _scroll.dispose();
    _voiceLevel.dispose();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _dismissGreeter() {
    if (!_greeterDismissed) {
      _pendingChatReveal = true;
      _chatRevealTimer?.cancel();
      _chatRevealTimer = Timer(const Duration(milliseconds: 450), () {
        _pendingChatReveal = false;
      });
    }
    _greeterDismissed = true;
  }

  bool _handleScrollEnd(ScrollEndNotification notification) {
    if (_snapping || _greeterDismissed || _messages.isEmpty) return false;
    final metrics = notification.metrics;
    final render = _greeterKey.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return false;
    final boundary = (render.size.height - metrics.viewportDimension * .35)
        .clamp(0.0, metrics.maxScrollExtent);
    if (boundary <= 0) return false;
    final pixels = metrics.pixels;
    if (pixels <= 1 || pixels >= boundary - 1) return false;
    _snapTo(pixels > 48 ? boundary : 0.0);
    return false;
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
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(() => _snapping = false),
      );
    });
  }

  void _trackShake(Offset position) {
    _lastShakePosition = position;
    final now = DateTime.now();
    final lastX = _lastShakeX;
    _lastShakeX = position.dx;
    if (lastX == null) return;
    final movement = position.dx - lastX;
    if (movement.abs() < 7) return;
    final direction = movement.isNegative ? -1 : 1;
    final elapsedMs = now.difference(_lastShakeReversalAt).inMilliseconds;
    if (isShakeReversal(_lastShakeDirection, direction, elapsedMs, movement)) {
      final progress = advanceShakeProgress(_shakeProgress, movement);
      setState(() => _shakeProgress = progress);
      if (progress >= 100) unawaited(_activateShakeVoice());
      _lastShakeReversalAt = now;
    } else if (direction != _lastShakeDirection) {
      _lastShakeReversalAt = now;
    }
    _lastShakeDirection = direction;
  }

  Future<void> _activateShakeVoice() async {
    if (_activatingShakeVoice) return;
    _activatingShakeVoice = true;
    setState(() => _shakeProgress = 0);
    try {
      if (widget.onShakeSummon case final summon?) {
        await summon();
      } else {
        await handleDesktopGesture(ShiftGestureAction.startVoice);
      }
    } finally {
      _activatingShakeVoice = false;
    }
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
                  .onError((failure, _) {
                    if (mounted) {
                      setState(() => _error = _describeError(failure));
                    }
                  }),
            );
            _activeRequestId = null;
            _progress = null;
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
          if (value.requestId == null ||
              value.requestId == _activeRequestId ||
              value.requestId!.startsWith('approval-')) {
            _error = value.message;
            if (value.requestId == _activeRequestId) {
              _activeRequestId = null;
              _progress = null;
            }
            if (value.requestId != null) {
              _removeProposalsForParent(value.requestId!);
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
          _messages.add(
            _ChatMessage(
              requestId:
                  'meeting-summary-${DateTime.now().microsecondsSinceEpoch}',
              text: [
                'Meeting summary: ${value.summary}',
                for (final action in value.actions) '• $action',
              ].join('\n'),
              fromUser: false,
            ),
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
    // A bare channel link code typed into the chat box is a link action, not a
    // message for the assistant — redeem it here and confirm inline.
    final code = ChannelLinkCode.tryParse(text);
    final channels = widget.services.channels;
    if (code != null && channels != null) {
      await _redeemLinkCode(channels, code);
      return;
    }
    _sending = true;
    try {
      final requestId = await widget.services.sendChatMessage(text: text);
      if (!mounted) return;
      setState(() {
        _messages.add(
          _ChatMessage(requestId: requestId, text: text, fromUser: true),
        );
        _activeRequestId = requestId;
        _dismissGreeter();
        _progress = 'Thinking';
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

  Future<void> _redeemLinkCode(ChannelClient channels, String code) async {
    _sending = true;
    setState(() {
      _messages.add(
        _ChatMessage(
          requestId: 'channel-link:$code',
          text: code,
          fromUser: true,
        ),
      );
      _dismissGreeter();
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
    final history = _historyBuildersNewestFirst();
    return MouseRegion(
      onHover: ready ? (event) => _trackShake(event.localPosition) : null,
      child: Stack(
        children: [
          // The scrollbar belongs to the window, not to the reading column:
          // painted inside the 680-wide column it lands on top of the task
          // rows. Suppress the implicit one the list would draw and hang an
          // explicit one off the full-width edge instead.
          Scrollbar(
            controller: _scroll,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
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
                          // Once the greeter is dismissed the conversation owns
                          // the viewport; reserving its slot would strand the
                          // newest messages below the fold.
                          final greeterExtent = _greeterDismissed
                              ? 0.0
                              : _messages.isEmpty
                              ? constraints.maxHeight
                              : math.max(
                                  0.0,
                                  constraints.maxHeight - _historyPeekExtent,
                                );
                          return Stack(
                            children: [
                              NotificationListener<ScrollEndNotification>(
                                onNotification: _handleScrollEnd,
                                child: ScrollConfiguration(
                                  behavior: ScrollConfiguration.of(
                                    context,
                                  ).copyWith(scrollbars: false),
                                  child: ListView.builder(
                                    key: const Key('chat_messages'),
                                    controller: _scroll,
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    reverse: true,
                                    // The message directly above the home view is
                                    // the peek, so it has to be built even when the
                                    // home view is taller than the viewport.
                                    scrollCacheExtent:
                                        const ScrollCacheExtent.pixels(800),
                                    itemCount: history.length + 1,
                                    itemBuilder: (context, index) {
                                      if (index == 0) {
                                        return KeyedSubtree(
                                          key: _greeterKey,
                                          child: ConstrainedBox(
                                            constraints: BoxConstraints(
                                              minHeight: greeterExtent,
                                            ),
                                            child: Center(
                                              child: _GreeterSwitcher(
                                                dismissed: _greeterDismissed,
                                                child: _ChatHome(
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
                                                  meetingNotes: _meetingNotes,
                                                  onOpenMeetingNotes:
                                                      _openMeetingNotes,
                                                  onComplete: currents == null
                                                      ? null
                                                      : (id) => unawaited(
                                                          currents.dismiss(id),
                                                        ),
                                                  onPrompt: _sendPrompt,
                                                  showByokHint:
                                                      !_byokHintDismissed &&
                                                      _byokPlanFree,
                                                  onOpenByok: widget
                                                      .onOpenProviderSettings,
                                                  onDismissByok: () =>
                                                      unawaited(
                                                        _dismissByokHint(),
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      }
                                      return history[index - 1]();
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
                                  child: IgnorePointer(
                                    child: _HistoryTopFade(),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
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
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_greeterDismissed)
            Positioned(
              top: 0,
              left: 0,
              child: _BackToHomeButton(
                key: const Key('chat_back'),
                onPressed: () => setState(() => _greeterDismissed = false),
              ),
            ),
          if (_shakeProgress > 0)
            IgnorePointer(
              child: _ShakeGlow(
                key: const Key('shake_glow'),
                position: _lastShakePosition,
                progress: _shakeProgress / 100,
              ),
            ),
        ],
      ),
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

  List<Widget Function()> _historyBuildersNewestFirst() {
    final history = <Widget Function()>[
      for (final message in _messages)
        () => _BlurFadeIn(
          key: ValueKey(
            'msg_fade_${message.requestId}_${message.fromUser ? 'user' : 'assistant'}',
          ),
          delayMs: _pendingChatReveal ? 220 : 0,
          child: message.fromUser
              ? Align(
                  alignment: Alignment.centerRight,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(message.text),
                    ),
                  ),
                )
              : _AssistantRow(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: AssistantMarkdown(message.text),
                    ),
                  ),
                ),
        ),
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
      if (_activeRequestId != null)
        () => _AssistantRow(
          spinning: true,
          child: _SkeletonBubble(
            key: const Key('chat_skeleton'),
            label: _progress,
          ),
        )
      else if (_progress != null)
        () => Text(_progress!, key: const Key('chat_progress')),
      if (_error != null)
        () => Text(
          _error!,
          key: const Key('chat_error'),
          style: const TextStyle(color: Colors.redAccent),
        ),
    ];
    return history.reversed.toList(growable: false);
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

class _GreeterSwitcher extends StatelessWidget {
  const _GreeterSwitcher({required this.dismissed, required this.child});

  final bool dismissed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 420),
      reverseDuration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, .04),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: dismissed
          ? const SizedBox.shrink(key: Key('hub_greeter_hidden'))
          : KeyedSubtree(
              key: const Key('hub_greeter'),
              child: disableAnimations
                  ? child
                  : _BlurFadeIn(
                      key: const Key('hub_greeter_blur_fade'),
                      child: child,
                    ),
            ),
    );
  }
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

class _BackToHomeButton extends StatelessWidget {
  const _BackToHomeButton({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = _HubColors.of(context);
    return Tooltip(
      message: 'Back to home',
      child: Material(
        color: colors.cardBg,
        shape: CircleBorder(side: BorderSide(color: colors.hairline)),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          hoverColor: colors.rowHover,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(Icons.arrow_back_rounded, size: 18, color: colors.ink),
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
    final page = dark ? const Color(0xff1c1c1a) : const Color(0xfff7f6f1);
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
            colors: [Color(0x55f25e6b), Color(0x00f25e6b)],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(1.15, -.9),
            radius: .9,
            colors: [Color(0x5596c4ff), Color(0x0096c4ff)],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(.9, 1.15),
            radius: .9,
            colors: [Color(0x55d3e081), Color(0x00d3e081)],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-1.1, 1.05),
            radius: .9,
            colors: [Color(0x55f2c2ac), Color(0x00f2c2ac)],
          ),
        ),
      ),
    ],
  );
}

class _ShakeGlow extends StatelessWidget {
  const _ShakeGlow({required this.position, required this.progress, super.key});

  final Offset position;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final size = 120 + progress * 360;
    return Positioned(
      left: position.dx - size / 2,
      top: position.dy - size / 2,
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              const Color(0xff96c4ff).withValues(alpha: progress * .55),
              const Color(0x0096c4ff),
            ],
          ),
        ),
      ),
    );
  }
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
    this.showByokHint = false,
    this.onOpenByok,
    this.onDismissByok,
  });

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
                const OmiActivityOrb(size: 48),
                const SizedBox(height: 16),
                Text(
                  greeting,
                  key: const Key('hub_greeting'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
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
                for (final task in tasks)
                  if (currentCrepusSource(task.metadata) case final crepus?)
                    // AI-authored current: render the constrained .crepus widget
                    // kit instead of the classic row (same slot). The action
                    // whitelist inside CrepusCurrentRow is the security boundary.
                    CrepusCurrentRow(
                      key: ValueKey('task_${task.item.id}'),
                      source: crepus,
                      palette: _crepusPalette(colors),
                      proposedNextStep: task.item.proposedNextStep,
                      onComplete: onComplete == null
                          ? null
                          : () => onComplete!(task.item.id),
                      onPrompt: onPrompt,
                    )
                  else if (task.metadata != null &&
                      HubTaskMeta.fromJson(task.metadata!) != null)
                    _RichTaskRow(
                      key: ValueKey('task_${task.item.id}'),
                      meta: HubTaskMeta.fromJson(task.metadata!)!,
                      done: false,
                      sourceTag: task.sourceKind,
                      completeKey: ValueKey('complete_${task.item.id}'),
                      onComplete: onComplete == null
                          ? null
                          : () => onComplete!(task.item.id),
                      onTap: () => onPrompt(task.item.proposedNextStep),
                    )
                  else
                    _TaskRow(
                      key: ValueKey('task_${task.item.id}'),
                      title: task.title,
                      done: false,
                      sourceTag: task.sourceKind,
                      completeKey: ValueKey('complete_${task.item.id}'),
                      onComplete: onComplete == null
                          ? null
                          : () => onComplete!(task.item.id),
                      onTap: () => onPrompt(task.item.proposedNextStep),
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

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.title,
    required this.done,
    required this.completeKey,
    required this.onComplete,
    required this.onTap,
    this.sourceTag,
    super.key,
  });

  final String title;
  final bool done;
  final Key completeKey;
  final VoidCallback? onComplete;
  final VoidCallback onTap;
  final String? sourceTag;

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
                  if (sourceTag case final tag?) ...[
                    const SizedBox(width: 16),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: colors.hairline),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        child: Text(
                          tag.toUpperCase(),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.17,
                            color: colors.muted,
                          ),
                        ),
                      ),
                    ),
                  ],
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
    this.sourceTag,
    super.key,
  });

  final HubTaskMeta meta;
  final bool done;
  final Key completeKey;
  final VoidCallback? onComplete;
  final VoidCallback onTap;
  final String? sourceTag;

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
                            if (sourceTag case final tag?)
                              Padding(
                                padding: const EdgeInsets.only(left: 10),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border.all(color: colors.hairline),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    child: Text(
                                      tag.toUpperCase(),
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 1.17,
                                        color: colors.muted,
                                      ),
                                    ),
                                  ),
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
/// bubble. [spinning] turns the mark fast to read as "thinking" while a reply
/// is still coming.
class _AssistantRow extends StatelessWidget {
  const _AssistantRow({required this.child, this.spinning = false});

  final Widget child;
  final bool spinning;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 4, right: 10),
        child: spinning
            ? const OmiActivityOrb.loading(size: 26)
            : const OmiActivityOrb(size: 26),
      ),
      Flexible(child: child),
    ],
  );
}

/// The placeholder shown while the assistant's reply is still streaming in —
/// shimmering lines instead of a spinner alone, so the wait reads as content
/// arriving rather than a stall. [label] surfaces the live status if there is
/// one ("Thinking", "Working on it…").
class _SkeletonBubble extends StatefulWidget {
  const _SkeletonBubble({this.label, super.key});

  final String? label;

  @override
  State<_SkeletonBubble> createState() => _SkeletonBubbleState();
}

class _SkeletonBubbleState extends State<_SkeletonBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (debugOmiOrbStatic ||
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false)) {
      _shimmer.stop();
    } else if (!_shimmer.isAnimating) {
      _shimmer.repeat();
    }
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = _HubColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final width in const [220.0, 260.0, 160.0])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _SkeletonLine(
                  width: width,
                  shimmer: _shimmer,
                  base: colors.hairline,
                  highlight: colors.rowHover,
                ),
              ),
            if (widget.label case final label?)
              Text(label, style: TextStyle(fontSize: 12, color: colors.muted)),
          ],
        ),
      ),
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({
    required this.width,
    required this.shimmer,
    required this.base,
    required this.highlight,
  });

  final double width;
  final Animation<double> shimmer;
  final Color base;
  final Color highlight;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: shimmer,
    builder: (context, _) {
      final t = shimmer.value;
      return Container(
        width: width,
        height: 10,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          gradient: LinearGradient(
            begin: Alignment(-1 - 2 * (1 - t), 0),
            end: Alignment(1 - 2 * (1 - t), 0),
            colors: [base, highlight, base],
            stops: const [0.35, 0.5, 0.65],
          ),
        ),
      );
    },
  );
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
                child: DecoratedBox(
                  key: ValueKey('meeting_note_card_${note.id}'),
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
                                note.title,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: colors.ink,
                                ),
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
                        Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: colors.hairline),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              child: Text(
                                'MEETING',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.17,
                                  color: colors.muted,
                                ),
                              ),
                            ),
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
                        'By the way, if you bring your own keys, Omi becomes '
                        'free.',
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
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool busy;
  final String hintText;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  @override
  State<_ChatInputCard> createState() => _ChatInputCardState();
}

class _ChatInputCardState extends State<_ChatInputCard> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_focusChanged);
    widget.controller.addListener(_focusChanged);
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
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    widget.controller.removeListener(_focusChanged);
    super.dispose();
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
            if (widget.busy && !disableAnimations)
              const Positioned.fill(
                child: IgnorePointer(
                  child: _ThinkingGlow(key: Key('input_thinking_glow')),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 13, 13, 13),
              child: _buildRow(colors),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(_HubColors colors) => Row(
    children: [
      Expanded(
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (widget.controller.text.isEmpty)
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
              readOnly: widget.busy,
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

class _ThinkingGlow extends StatefulWidget {
  const _ThinkingGlow({super.key});

  @override
  State<_ThinkingGlow> createState() => _ThinkingGlowState();
}

class _ThinkingGlowState extends State<_ThinkingGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _pulse,
    builder: (context, child) {
      final glow = Curves.easeInOut.transform(_pulse.value);
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xfff2c2ac).withValues(alpha: .16 + .24 * glow),
            width: 1.5,
          ),
        ),
      );
    },
  );
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
