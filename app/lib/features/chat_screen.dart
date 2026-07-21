import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../keyboard/keyboard.dart';
import '../native/generated/signals/signals.dart'
    show ComputerUseAction, ComputerUseActionClick, ComputerUseActionTypeText;
import '../native/native_hub.dart';
import '../ui/omi_ui.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.services,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final bool previewMode;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _desktopKeyboard = DesktopKeyboard();
  final _messages = <_ChatMessage>[];
  final _proposals = <String, ActionProposal>{};
  final _proposalExpiryTimers = <String, Timer>{};
  StreamSubscription<NativeEvent>? _events;
  StreamSubscription<int>? _authorityChanges;
  DesktopGestureController? _desktopGesture;
  StreamSubscription<ShiftGestureAction>? _desktopGestureActions;
  String? _activeRequestId;
  String? _progress;
  String? _error;
  bool _sending = false;
  int _conversationLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    if (!widget.previewMode) {
      unawaited(_loadConversation());
      _events = widget.services.nativeEvents.listen(_handleEvent);
      _authorityChanges = widget.services.chatAuthorityChanges.listen((_) {
        if (!mounted) return;
        _conversationLoadGeneration += 1;
        setState(() {
          _messages.clear();
          _activeRequestId = null;
          _proposals.clear();
          for (final timer in _proposalExpiryTimers.values) {
            timer.cancel();
          }
          _proposalExpiryTimers.clear();
          _progress = null;
          _error = 'Chat authority changed. Reconnect before continuing.';
        });
        if (widget.services.auth.snapshot.hasProcessingAuthority) {
          unawaited(_loadConversation());
        }
      });
      if (_desktopKeyboard.supported) {
        _desktopGesture = DesktopGestureController(keyboard: _desktopKeyboard)
          ..start();
        _desktopGestureActions = _desktopGesture!.actions.listen(
          _handleDesktopGesture,
        );
      }
    }
  }

  Future<void> _handleDesktopGesture(ShiftGestureAction action) async {
    if (!mounted) return;
    switch (action) {
      case ShiftGestureAction.openTextInput:
        await _desktopKeyboard.focusApplication();
        if (mounted) _inputFocus.requestFocus();
      case ShiftGestureAction.submitText:
        await _send();
      case ShiftGestureAction.cancel:
        if (_activeRequestId != null) {
          _cancel();
        } else {
          _input.clear();
          _inputFocus.unfocus();
        }
      case ShiftGestureAction.startVoice ||
          ShiftGestureAction.continueVoice ||
          ShiftGestureAction.stopVoice:
        setState(() {
          _error = 'Desktop microphone capture is not connected yet.';
        });
    }
  }

  Future<void> _loadConversation() async {
    final generation = _conversationLoadGeneration;
    try {
      final messages = await widget.services.replayConversation();
      if (!mounted || generation != _conversationLoadGeneration) return;
      setState(() {
        for (final message in messages) {
          if (_messages.any(
            (existing) => existing.requestId == message.clientMessageId,
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
      });
    } catch (failure) {
      if (mounted && generation == _conversationLoadGeneration) {
        setState(() => _error = failure.toString());
      }
    }
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_authorityChanges?.cancel());
    unawaited(_desktopGestureActions?.cancel());
    unawaited(_desktopGesture?.dispose());
    for (final timer in _proposalExpiryTimers.values) {
      timer.cancel();
    }
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
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

  void _decide(ActionProposal proposal, ApprovalDecision decision) {
    try {
      widget.services.decideChatApproval(
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
    ComputerUseActionClick(:final x, :final y, :final button, :final count) =>
      Text(
        'Click ${button.name} at ($x, $y) ${count == 1 ? 'once' : '$count times'}',
        key: const Key('computer_action_details'),
      ),
    ComputerUseActionTypeText(
      :final text,
      :final clear,
      :final pressReturn,
      :final delayMs,
    ) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Exact text to type'),
          const SizedBox(height: 4),
          SelectableText(text, key: const Key('computer_action_text')),
          const SizedBox(height: 6),
          Text(
            '${clear ? 'Clears the focused field first' : 'Keeps existing field contents'} · '
            '${pressReturn ? 'Presses Return after typing' : 'Does not press Return'} · '
            'Delay: ${delayMs?.toString() ?? 'default'} ms',
            key: const Key('computer_action_details'),
          ),
        ],
      ),
    _ => const Text(
      'Unknown computer action',
      key: Key('computer_action_details'),
    ),
  };

  @override
  Widget build(BuildContext context) {
    final ready = !widget.previewMode && widget.services.chatReady;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageTitle(
          title: 'Chat',
          subtitle: 'Your thinking partner across every connected device.',
        ),
        const SizedBox(height: 20),
        Expanded(
          child: ListView(
            key: const Key('chat_messages'),
            children: [
              if (_messages.isEmpty && _proposals.isEmpty)
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.forum_outlined, size: 36),
                            const SizedBox(height: 14),
                            Text(
                              ready
                                  ? 'Ask Omi anything'
                                  : 'Chat is not connected yet',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              ready
                                  ? 'Messages run through your configured native assistant.'
                                  : 'Finish account, consent, and model setup before sending your first message.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white60),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              for (final message in _messages)
                Align(
                  alignment: message.fromUser
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(message.text),
                    ),
                  ),
                ),
              for (final proposal in _proposals.values)
                Card(
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
                        if (proposal.computerAction case final action?) ...[
                          const SizedBox(height: 10),
                          _computerActionDetails(action),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            FilledButton(
                              key: ValueKey('approve_${proposal.proposalId}'),
                              onPressed: () => _decide(
                                proposal,
                                ApprovalDecision.approveOnce,
                              ),
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
                Text(_progress!, key: const Key('chat_progress')),
              if (_error != null)
                Text(
                  _error!,
                  key: const Key('chat_error'),
                  style: const TextStyle(color: Colors.redAccent),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('chat_input'),
          controller: _input,
          focusNode: _inputFocus,
          enabled: ready,
          readOnly: _activeRequestId != null,
          onSubmitted: (_) => _send(),
          decoration: InputDecoration(
            hintText: ready
                ? 'Message Omi'
                : 'Connect an account and model to start chatting',
            prefixIcon: const Icon(Icons.add_circle_outline_rounded),
            suffixIcon: _activeRequestId == null
                ? IconButton(
                    key: const Key('send_chat'),
                    onPressed: ready ? _send : null,
                    icon: const Icon(Icons.arrow_upward_rounded),
                  )
                : IconButton(
                    key: const Key('cancel_chat'),
                    onPressed: _cancel,
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
          ),
        ),
      ],
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
