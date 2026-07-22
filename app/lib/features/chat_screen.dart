import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
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

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.services,
    this.previewMode = false,
    this.desktopKeyboard,
    this.onDesktopGestureReset,
    this.checklistStore,
    super.key,
  });

  final AppServices services;
  final bool previewMode;
  final DesktopKeyboard? desktopKeyboard;
  final VoidCallback? onDesktopGestureReset;
  final HubChecklistStore? checklistStore;

  @override
  State<ChatScreen> createState() => ChatScreenState();
}

const _kInk = Color(0xff171716);
const _kMuted = Color(0xff8d8980);
const _kHairline = Color(0x1a000000);
const _kHintBlue = Color(0xff3139fb);

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
  bool _setupTaskDone = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadChecklist());
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
    try {
      done = await _checklist.isSetupComplete();
    } catch (_) {
      done = true;
    }
    if (mounted && done != _setupTaskDone) {
      setState(() => _setupTaskDone = done);
    }
  }

  void _toggleSetupTask() {
    setState(() => _setupTaskDone = !_setupTaskDone);
    unawaited(
      _checklist.setSetupComplete(_setupTaskDone).catchError((Object _) {}),
    );
  }

  Future<void> _refreshCurrents() async {
    final currents = widget.services.currents;
    if (currents == null || !widget.services.chatReady) return;
    await currents.load();
  }

  Future<void> handleDesktopGesture(ShiftGestureAction action) async {
    if (!mounted) return;
    switch (action) {
      case ShiftGestureAction.openTextInput:
        await _desktopKeyboard.focusApplication();
        if (mounted) _inputFocus.requestFocus();
      case ShiftGestureAction.submitText:
        await _send();
      case ShiftGestureAction.cancel:
        if (widget.services.desktopVoice.active) {
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
          if (mounted) setState(() => _error = failure.toString());
        }
      case ShiftGestureAction.continueVoice:
        try {
          await widget.services.continueDesktopVoice();
          if (mounted) setState(() => _progress = 'Listening');
        } catch (failure) {
          widget.onDesktopGestureReset?.call();
          if (mounted) setState(() => _error = failure.toString());
        }
      case ShiftGestureAction.stopVoice:
        try {
          final submission = await widget.services.stopDesktopVoice();
          if (!mounted) return;
          setState(() {
            _progress = submission == null ? null : 'Thinking';
            if (submission != null) {
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
          if (mounted) setState(() => _error = failure.toString());
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
        setState(() => _error = failure.toString());
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
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
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
      await handleDesktopGesture(ShiftGestureAction.startVoice);
      if (!mounted) return;
      await handleDesktopGesture(ShiftGestureAction.continueVoice);
    } finally {
      _activatingShakeVoice = false;
    }
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
                    if (mounted) setState(() => _error = failure.toString());
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
        default:
          break;
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _activeRequestId != null || _sending) return;
    _sending = true;
    try {
      final requestId = await widget.services.sendChatMessage(text: text);
      if (!mounted) return;
      setState(() {
        _messages.add(
          _ChatMessage(requestId: requestId, text: text, fromUser: true),
        );
        _activeRequestId = requestId;
        _progress = 'Thinking';
        _error = null;
        _input.clear();
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _activeRequestId = null;
        _progress = null;
        _error = failure.toString();
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
      setState(() => _error = failure.toString());
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
    final ready = !widget.previewMode && widget.services.chatReady;
    final voiceActive = widget.services.desktopVoice.active;
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
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ListView.builder(
                      key: const Key('chat_messages'),
                      reverse: true,
                      itemCount: history.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return _ChatHome(
                            greeting: _greeting(),
                            setupTaskDone: _setupTaskDone,
                            onToggleSetupTask: _toggleSetupTask,
                            tasks: tasks,
                            onComplete: currents == null
                                ? null
                                : (id) => unawaited(currents.dismiss(id)),
                            onPrompt: _usePrompt,
                          );
                        }
                        return history[index - 1]();
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
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Listening',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              TextButton(
                key: const Key('stop_listening'),
                onPressed: () => unawaited(
                  handleDesktopGesture(ShiftGestureAction.stopVoice),
                ),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget Function()> _historyBuildersNewestFirst() {
    final history = <Widget Function()>[
      for (final message in _messages)
        () => Align(
          alignment: message.fromUser
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: message.fromUser
                  ? Text(message.text)
                  : AssistantMarkdown(message.text),
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
      if (_progress != null)
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
    required this.tasks,
    required this.onComplete,
    required this.onPrompt,
  });

  final String greeting;
  final bool setupTaskDone;
  final VoidCallback onToggleSetupTask;
  final List<CurrentCard> tasks;
  final ValueChanged<String>? onComplete;
  final ValueChanged<String> onPrompt;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Reveal(
          delayMs: 0,
          child: Column(
            children: [
              const OmiActivityOrb(state: OmiOrbState.idle, size: 48),
              const SizedBox(height: 16),
              Text(
                greeting,
                key: const Key('hub_greeting'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -1.98,
                  color: _kInk,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 36),
        _Reveal(
          delayMs: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'WHAT MATTERS NEXT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.43,
                    color: _kMuted,
                  ),
                ),
              ),
              _TaskRow(
                key: const Key('task_setup_omi'),
                title: 'Set up Omi.',
                done: setupTaskDone,
                completeKey: const Key('complete_setup_omi'),
                onComplete: onToggleSetupTask,
                onTap: onToggleSetupTask,
              ),
              for (final task in tasks)
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
              const _HintRow(),
            ],
          ),
        ),
      ],
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
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: _kHairline)),
    ),
    child: InkWell(
      onTap: onTap,
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
                    border: Border.all(color: _kMuted),
                  ),
                  child: done
                      ? const Text(
                          '✓',
                          style: TextStyle(fontSize: 10, color: _kInk),
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
                    color: _kInk,
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
                    border: Border.all(color: _kHairline),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: Text(
                      tag.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.17,
                        color: _kMuted,
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
  );
}

class _HintRow extends StatelessWidget {
  const _HintRow();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: _kHairline),
        bottom: BorderSide(color: _kHairline),
      ),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text('↳', style: TextStyle(fontSize: 14, color: _kHintBlue)),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Text(
              'By the way, if you bring your own keys, Omi becomes free.',
              style: TextStyle(
                fontSize: 12,
                height: 20 / 12,
                color: _kHintBlue,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ChatInputCard extends StatelessWidget {
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
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _kHairline),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0a000000),
          offset: Offset(0, 14),
          blurRadius: 44,
        ),
      ],
    ),
    padding: const EdgeInsets.fromLTRB(20, 13, 13, 13),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('chat_input'),
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            readOnly: busy,
            onSubmitted: (_) => onSend(),
            style: const TextStyle(fontSize: 15, color: _kInk),
            decoration: InputDecoration(
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText: hintText,
              hintStyle: const TextStyle(fontSize: 15, color: _kMuted),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 38,
          height: 38,
          child: busy
              ? IconButton(
                  key: const Key('cancel_chat'),
                  onPressed: onCancel,
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    backgroundColor: _kInk,
                    foregroundColor: Colors.white,
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.stop_rounded, size: 18),
                )
              : IconButton(
                  key: const Key('send_chat'),
                  onPressed: enabled ? onSend : null,
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    backgroundColor: _kInk,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0x33171716),
                    disabledForegroundColor: Colors.white,
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                ),
        ),
      ],
    ),
  );
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
