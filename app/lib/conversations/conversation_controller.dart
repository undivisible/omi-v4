import 'dart:async';
import 'dart:math';

import '../currents/currents.dart';
import '../native/native_hub.dart';
import 'conversations.dart';

enum _ChatRequestKind { message, approval }

typedef _ChatRequest = ({int generation, _ChatRequestKind kind});
typedef _ChatProposal = ({
  int generation,
  String parentRequestId,
  String? operationId,
  String? actionHash,
  ActionRisk risk,
  bool executable,
});
typedef _PendingApproval = ({
  String proposalId,
  ApprovalDecision decision,
  CurrentActionHandoff? handoff,
});

const _completedRequestCapacity = 256;

String _randomId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String _boundedText(String value, int maxLength) {
  if (value.length <= maxLength) return value;
  var end = maxLength;
  final last = value.codeUnitAt(end - 1);
  if (last >= 0xd800 && last <= 0xdbff) end -= 1;
  return value.substring(0, end);
}

String _riskName(ActionRisk risk) => switch (risk) {
  ActionRisk.reversible => 'reversible',
  ActionRisk.external => 'external',
  ActionRisk.destructive => 'destructive',
};

final class _ActiveInboxItem {
  _ActiveInboxItem({
    required this.item,
    required this.requestId,
    required this.generation,
  });

  final ConversationInboxItem item;
  final String requestId;
  final int generation;
  final response = StringBuffer();
  String? approvalResponse;
  bool completing = false;
}

final class ConversationController {
  factory ConversationController({
    required NativeHub nativeHub,
    required ConversationTransport? transport,
    required ConversationInboxTransport? inbox,
    required CurrentsClient? currents,
    required String source,
    required DateTime Function() now,
    required bool Function() isReady,
    bool Function()? isLocalOnly,
    required bool Function() isDisposed,
    required String? Function() currentUid,
    required Future<String?> Function() currentIdToken,
    required bool canPollInbox,
    required void Function(Object error, StackTrace stackTrace) addError,
    required Duration inboxPollInterval,
  }) => ConversationController._(
    nativeHub,
    transport,
    inbox,
    currents,
    source,
    now,
    isReady,
    isLocalOnly ?? (() => false),
    isDisposed,
    currentUid,
    currentIdToken,
    canPollInbox,
    addError,
    inboxPollInterval,
  );

  ConversationController._(
    this._nativeHub,
    this._transport,
    this._inbox,
    this._currents,
    this._source,
    this._now,
    this._isReady,
    this._isLocalOnly,
    this._isDisposed,
    this._currentUid,
    this._currentIdToken,
    this._canPollInbox,
    this._addError,
    this._inboxPollInterval,
  );

  final NativeHub _nativeHub;
  final ConversationTransport? _transport;
  final ConversationInboxTransport? _inbox;
  final CurrentsClient? _currents;
  final String _source;
  final DateTime Function() _now;
  final bool Function() _isReady;
  final bool Function() _isLocalOnly;
  final bool Function() _isDisposed;
  final String? Function() _currentUid;
  final Future<String?> Function() _currentIdToken;
  final bool _canPollInbox;
  final void Function(Object error, StackTrace stackTrace) _addError;
  final Duration _inboxPollInterval;
  final _authorityChanges = StreamController<int>.broadcast(sync: true);
  final String _sessionId = _randomId();
  int _generation = 0;
  int _transportSequence = 0;
  final _requests = <String, _ChatRequest>{};
  final _proposals = <String, _ChatProposal>{};
  final _pendingApprovals = <String, _PendingApproval>{};
  final _approvalRequestByProposal = <String, String>{};
  final _handoffsByChatRequest = <String, CurrentActionHandoff>{};
  final _handoffsByProposal = <String, CurrentActionHandoff>{};
  final _terminalRequests = <String>{};
  Timer? _inboxPollTimer;
  _ActiveInboxItem? _activeInboxItem;
  bool _inboxPollRunning = false;

  int get authorityGeneration => _generation;
  Stream<int> get authorityChanges => _authorityChanges.stream;

  Future<String> send({
    required String text,
    CurrentActionHandoff? currentHandoff,
    MessageOrigin origin = MessageOrigin.chat,
  }) async {
    if (!_isReady()) {
      throw StateError(
        'Sign in, grant consent, and connect native services first.',
      );
    }
    final requestId = 'chat-$_sessionId-g$_generation-${_transportSequence++}';
    _requests[requestId] = (
      generation: _generation,
      kind: _ChatRequestKind.message,
    );
    if (currentHandoff != null) {
      _handoffsByChatRequest[requestId] = currentHandoff;
    }
    try {
      if (!_isLocalOnly()) {
        await _transport?.append(
          clientMessageId: requestId,
          role: 'user',
          source: _source,
          text: text,
        );
      }
      _nativeHub.sendMessage(requestId: requestId, text: text, origin: origin);
      return requestId;
    } catch (_) {
      _requests.remove(requestId);
      _handoffsByChatRequest.remove(requestId);
      rethrow;
    }
  }

  Future<void> saveAssistantMessage({
    required String requestId,
    required String text,
  }) async {
    if (_isLocalOnly()) return;
    await _transport?.append(
      clientMessageId: 'assistant:$requestId',
      role: 'assistant',
      source: _source,
      text: text,
    );
  }

  Future<List<ConversationMessage>> replay({int after = 0}) =>
      _isLocalOnly() || _transport == null
      ? Future.value(const [])
      : _transport.replay(after: after);

  Future<String> handoff(CurrentActionHandoff handoff) async {
    if (_currents == null) {
      throw StateError('Currents are not connected.');
    }
    return send(text: handoff.instruction, currentHandoff: handoff);
  }

  Future<String> decide({
    required String proposalId,
    required ApprovalDecision decision,
  }) async {
    if (!_isReady()) {
      throw StateError('Native services are not connected.');
    }
    final proposal = _proposals[proposalId];
    if (proposal == null || proposal.generation != _generation) {
      throw StateError('This action proposal is unavailable.');
    }
    if (_approvalRequestByProposal.containsKey(proposalId)) {
      throw StateError('This action proposal is already being decided.');
    }
    final requestId = 'approval-g$_generation-${_transportSequence++}';
    _requests[requestId] = (
      generation: _generation,
      kind: _ChatRequestKind.approval,
    );
    _pendingApprovals[requestId] = (
      proposalId: proposalId,
      decision: decision,
      handoff: null,
    );
    _approvalRequestByProposal[proposalId] = requestId;
    final handoff = _handoffsByProposal[proposalId];
    CurrentApprovalReceipt? receipt;
    try {
      if (handoff != null && _currents != null) {
        if (decision == ApprovalDecision.approveOnce && proposal.executable) {
          final uid = _currentUid();
          var token = await _currentIdToken();
          if (uid == null || token == null || token.isEmpty) {
            throw StateError('Current approval authority is unavailable.');
          }
          receipt = await _currents.approve(
            handoff,
            subject: uid,
            proposalId: proposalId,
            operationId: proposal.operationId!,
            actionHash: proposal.actionHash!,
            risk: _riskName(proposal.risk),
          );
          token = await _currentIdToken();
          final pending = _pendingApprovals[requestId];
          if (pending == null ||
              proposal.generation != _generation ||
              _currentUid() != uid ||
              token == null ||
              token.isEmpty ||
              receipt.expiresAtMs <= _now().millisecondsSinceEpoch) {
            await _currents.recordOutcome(
              handoff,
              CurrentExecutionOutcome.failed,
              'Local authority changed before native dispatch.',
            );
            receipt = null;
            throw StateError('Current approval authority changed.');
          }
          _pendingApprovals[requestId] = (
            proposalId: proposalId,
            decision: decision,
            handoff: handoff,
          );
          _nativeHub.decideApproval(
            requestId: requestId,
            proposalId: proposalId,
            decision: decision,
            authorityReceipt: ComputerUseAuthorityReceipt(
              version: receipt.version,
              executionId: handoff.executionId,
              receiptId: receipt.receiptId,
              receiptToken: receipt.receiptToken,
              firebaseToken: token,
              subject: receipt.subject,
              policyGeneration: Uint64.fromBigInt(
                BigInt.from(receipt.policyGeneration),
              ),
              operationId: receipt.operationId,
              proposalId: receipt.proposalId,
              actionHash: receipt.actionHash,
              risk: proposal.risk,
              issuedAtMs: receipt.issuedAtMs,
              expiresAtMs: receipt.expiresAtMs,
            ),
          );
          return requestId;
        }
        await _currents.reject(handoff);
      }
      _nativeHub.decideApproval(
        requestId: requestId,
        proposalId: proposalId,
        decision: decision,
      );
    } catch (_) {
      if (receipt != null && handoff != null && _currents != null) {
        unawaited(
          _currents
              .recordOutcome(
                handoff,
                CurrentExecutionOutcome.outcomeUnknown,
                'Native dispatch outcome is unknown; automatic retry is prohibited.',
              )
              .onError((error, stack) {
                _addError(
                  error ?? StateError('Currents outcome failed.'),
                  stack,
                );
              }),
        );
      }
      _requests.remove(requestId);
      _pendingApprovals.remove(requestId);
      _approvalRequestByProposal.remove(proposalId);
      rethrow;
    }
    return requestId;
  }

  void cancel(String requestId) {
    final request = _requests[requestId];
    if (request == null || request.generation != _generation) return;
    final pendingApproval = _pendingApprovals[requestId];
    if (pendingApproval != null) {
      _finishApprovalCorrelation(requestId, pendingApproval.proposalId);
    } else {
      _requests.remove(requestId);
      _tombstone(requestId);
      _invalidateProposals(requestId);
    }
    if (_isReady()) _nativeHub.cancel(requestId);
  }

  void scheduleInboxPoll([Duration? delay]) {
    if (!_canPollInbox ||
        !_isReady() ||
        _isDisposed() ||
        _activeInboxItem != null ||
        _inboxPollRunning ||
        _inboxPollTimer != null) {
      return;
    }
    _inboxPollTimer = Timer(delay ?? _inboxPollInterval, () {
      _inboxPollTimer = null;
      unawaited(_pollInbox());
    });
  }

  Future<void> _pollInbox() async {
    final inbox = _inbox;
    final uid = _currentUid();
    if (inbox == null ||
        _isDisposed() ||
        !_isReady() ||
        uid == null ||
        _inboxPollRunning) {
      return;
    }
    final generation = _generation;
    _inboxPollRunning = true;
    try {
      final item = await inbox.claim();
      if (_isDisposed() ||
          generation != _generation ||
          !_isReady() ||
          _currentUid() != uid ||
          item == null) {
        return;
      }
      final requestId = 'chat-channel:${item.id}:${item.attempt}';
      final active = _ActiveInboxItem(
        item: item,
        requestId: requestId,
        generation: generation,
      );
      _activeInboxItem = active;
      _requests[requestId] = (
        generation: generation,
        kind: _ChatRequestKind.message,
      );
      try {
        _nativeHub.sendMessage(
          requestId: requestId,
          text: item.text,
          memoryContext: item.memoryContext,
        );
      } catch (error) {
        _requests.remove(requestId);
        _tombstone(requestId);
        await _finishInboxItem(
          active,
          outcome: ConversationInboxOutcome.retry,
          error: error.toString(),
        );
      }
    } catch (error, stackTrace) {
      _addError(error, stackTrace);
    } finally {
      _inboxPollRunning = false;
      scheduleInboxPoll();
    }
  }

  bool handleNativeEvent(NativeEvent event) {
    if (!_acceptEvent(event)) return false;
    _handleInboxEvent(event);
    return true;
  }

  void _handleInboxEvent(NativeEvent event) {
    final active = _activeInboxItem;
    if (active == null || active.generation != _generation) return;
    if (event case NativeEventActionProposal(
      :final value,
    ) when value.requestId == active.requestId) {
      active.approvalResponse =
          'Approval required on desktop: ${value.title} — ${value.summary}';
      return;
    }
    if (event case NativeEventAssistantDelta(
      :final value,
    ) when value.requestId == active.requestId) {
      active.response.write(value.text);
      if (value.finalSegment) {
        final streamedResponse = active.response.toString().trim();
        final response = streamedResponse.isEmpty
            ? active.approvalResponse ?? ''
            : streamedResponse;
        unawaited(
          _finishInboxItem(
            active,
            outcome: response.isEmpty
                ? ConversationInboxOutcome.retry
                : ConversationInboxOutcome.done,
            responseText: response.isEmpty
                ? null
                : _boundedText(response, 4096),
            error: response.isEmpty
                ? 'Assistant returned an empty reply.'
                : null,
          ),
        );
      }
      return;
    }
    if (event case NativeEventError(
      :final value,
    ) when value.requestId == active.requestId) {
      unawaited(
        _finishInboxItem(
          active,
          outcome: ConversationInboxOutcome.retry,
          error: value.message,
        ),
      );
      return;
    }
    if (event case NativeEventToolProgress(:final value)
        when value.requestId == active.requestId &&
            (value.status == ToolStatus.failed ||
                value.status == ToolStatus.cancelled)) {
      unawaited(
        _finishInboxItem(
          active,
          outcome: ConversationInboxOutcome.retry,
          error: value.detail ?? value.status.name,
        ),
      );
    }
  }

  Future<void> _finishInboxItem(
    _ActiveInboxItem active, {
    required ConversationInboxOutcome outcome,
    String? responseText,
    String? error,
  }) async {
    if (!identical(_activeInboxItem, active) ||
        active.generation != _generation ||
        !_isReady() ||
        active.completing) {
      return;
    }
    active.completing = true;
    try {
      await _inbox!.complete(
        active.item,
        outcome: outcome,
        responseText: responseText,
        error: error == null ? null : _boundedText(error, 1000),
      );
    } catch (failure, stackTrace) {
      active.completing = false;
      _addError(failure, stackTrace);
      if (!identical(_activeInboxItem, active) ||
          active.generation != _generation ||
          !_isReady()) {
        return;
      }
      final remaining = active.item.leaseUntil - _now().millisecondsSinceEpoch;
      if (remaining <= 0) {
        _activeInboxItem = null;
        scheduleInboxPoll(Duration.zero);
        return;
      }
      _inboxPollTimer = Timer(
        Duration(
          milliseconds: min(_inboxPollInterval.inMilliseconds, remaining),
        ),
        () {
          _inboxPollTimer = null;
          unawaited(
            _finishInboxItem(
              active,
              outcome: outcome,
              responseText: responseText,
              error: error,
            ),
          );
        },
      );
      return;
    }
    active.completing = false;
    if (identical(_activeInboxItem, active)) _activeInboxItem = null;
    scheduleInboxPoll(Duration.zero);
  }

  bool _acceptEvent(NativeEvent event) {
    if (event case NativeEventApprovalDecisionAcknowledged(:final value)) {
      final pending = _pendingApprovals[value.requestId];
      if (pending == null ||
          pending.proposalId != value.proposalId ||
          pending.decision != value.decision) {
        return false;
      }
      if (!value.accepted) {
        return true;
      }
      _proposals.remove(pending.proposalId);
      _handoffsByProposal.remove(pending.proposalId);
      if (!value.executionPending) {
        if (pending.handoff case final handoff?) {
          _recordCurrentOutcome(
            handoff,
            CurrentExecutionOutcome.failed,
            'Native execution did not start.',
          );
        }
        _finishApprovalCorrelation(value.requestId, pending.proposalId);
      }
      return true;
    }
    if (event case NativeEventActionProposal(:final value)) {
      final parent = _requests[value.requestId];
      if (parent == null ||
          parent.kind != _ChatRequestKind.message ||
          parent.generation != _generation ||
          _proposals.containsKey(value.proposalId) ||
          _terminalRequests.contains(value.requestId) ||
          (value.expiresAtMs != null &&
              value.expiresAtMs! <= DateTime.now().millisecondsSinceEpoch)) {
        return false;
      }
      _proposals[value.proposalId] = (
        generation: _generation,
        parentRequestId: value.requestId,
        operationId: value.operationId,
        actionHash: value.actionHash,
        risk: value.risk,
        executable:
            value.computerAction != null &&
            value.operationId != null &&
            value.actionHash != null,
      );
      final handoff = _handoffsByChatRequest[value.requestId];
      if (handoff != null) _handoffsByProposal[value.proposalId] = handoff;
      return true;
    }
    String? requestId;
    var terminal = false;
    var requiresMessage = false;
    if (event case NativeEventAssistantDelta(:final value)) {
      requestId = value.requestId;
      terminal = value.finalSegment;
      requiresMessage = true;
    } else if (event case NativeEventToolProgress(:final value)) {
      requestId = value.requestId;
      final request = _requests[requestId];
      terminal =
          value.status == ToolStatus.failed ||
          value.status == ToolStatus.cancelled ||
          (request?.kind == _ChatRequestKind.approval &&
              value.status == ToolStatus.complete);
    } else if (event case NativeEventError(:final value)) {
      requestId = value.requestId;
      if (requestId == null ||
          (!requestId.startsWith('chat-') &&
              !requestId.startsWith('approval-'))) {
        return true;
      }
      terminal = true;
    } else {
      return true;
    }
    final request = _requests[requestId];
    if (request == null ||
        request.generation != _generation ||
        (requiresMessage && request.kind != _ChatRequestKind.message) ||
        _terminalRequests.contains(requestId)) {
      return false;
    }
    if (terminal) {
      final pendingApproval = _pendingApprovals[requestId];
      final currentHandoff = pendingApproval?.handoff;
      if (currentHandoff != null && _currents != null) {
        final outcome = switch (event) {
          NativeEventToolProgress(:final value)
              when value.status == ToolStatus.complete =>
            CurrentExecutionOutcome.succeeded,
          NativeEventError(:final value)
              when value.code == 'computer_use_outcome_unknown' =>
            CurrentExecutionOutcome.outcomeUnknown,
          NativeEventError(:final value)
              when value.code == 'computer_use_expired' ||
                  value.code == 'proposal_expired' =>
            CurrentExecutionOutcome.expiredBeforeEffect,
          NativeEventToolProgress(:final value)
              when value.status == ToolStatus.cancelled =>
            CurrentExecutionOutcome.cancelledBeforeEffect,
          _ => CurrentExecutionOutcome.failed,
        };
        final detail = switch (outcome) {
          CurrentExecutionOutcome.succeeded =>
            'Approved computer action completed.',
          CurrentExecutionOutcome.outcomeUnknown =>
            'Approved computer action outcome is unknown; automatic retry is prohibited.',
          CurrentExecutionOutcome.cancelledBeforeEffect =>
            'Approved computer action was cancelled before any effect.',
          CurrentExecutionOutcome.expiredBeforeEffect =>
            'Approved computer action expired before any effect.',
          CurrentExecutionOutcome.failed => 'Native execution failed.',
        };
        _recordCurrentOutcome(currentHandoff, outcome, detail);
      }
      if (pendingApproval != null) {
        _finishApprovalCorrelation(requestId, pendingApproval.proposalId);
      } else {
        _requests.remove(requestId);
        _tombstone(requestId);
      }
      final failedParent =
          event is NativeEventError ||
          (event is NativeEventToolProgress &&
              (event.value.status == ToolStatus.failed ||
                  event.value.status == ToolStatus.cancelled));
      if (failedParent) _invalidateProposals(requestId);
      if (request.kind == _ChatRequestKind.message) {
        final pendingCurrent = _handoffsByChatRequest.remove(requestId);
        final hasProposal = _proposals.values.any(
          (proposal) => proposal.parentRequestId == requestId,
        );
        if (pendingCurrent != null && !hasProposal && _currents != null) {
          unawaited(
            _currents.reject(pendingCurrent).onError((error, stack) {
              _addError(
                error ?? StateError('Currents rejection failed.'),
                stack,
              );
            }),
          );
        }
      }
    }
    return true;
  }

  void _tombstone(String requestId) {
    _terminalRequests.add(requestId);
    if (_terminalRequests.length > _completedRequestCapacity) {
      _terminalRequests.remove(_terminalRequests.first);
    }
  }

  void _invalidateProposals(String parentRequestId) {
    final proposalIds = _proposals.entries
        .where((entry) => entry.value.parentRequestId == parentRequestId)
        .map((entry) => entry.key)
        .toList();
    for (final proposalId in proposalIds) {
      _proposals.remove(proposalId);
      _handoffsByProposal.remove(proposalId);
    }
  }

  void _finishApprovalCorrelation(String requestId, String proposalId) {
    _pendingApprovals.remove(requestId);
    if (_approvalRequestByProposal[proposalId] == requestId) {
      _approvalRequestByProposal.remove(proposalId);
    }
    _requests.remove(requestId);
    _tombstone(requestId);
  }

  void _recordCurrentOutcome(
    CurrentActionHandoff handoff,
    CurrentExecutionOutcome outcome,
    String detail,
  ) {
    final currents = _currents;
    if (currents == null) return;
    unawaited(
      currents.recordOutcome(handoff, outcome, detail).onError((error, stack) {
        _addError(error ?? StateError('Currents outcome failed.'), stack);
      }),
    );
  }

  int fence({required bool cancelPending}) {
    _generation += 1;
    _inboxPollTimer?.cancel();
    _inboxPollTimer = null;
    _activeInboxItem = null;
    if (cancelPending) {
      for (final requestId in _requests.keys) {
        try {
          _nativeHub.cancel(requestId);
        } catch (_) {}
      }
    }
    for (final requestId in _requests.keys) {
      _tombstone(requestId);
    }
    _requests.clear();
    _proposals.clear();
    _pendingApprovals.clear();
    _approvalRequestByProposal.clear();
    _handoffsByChatRequest.clear();
    _handoffsByProposal.clear();
    _authorityChanges.add(_generation);
    return _generation;
  }

  Future<void> dispose() async {
    _inboxPollTimer?.cancel();
    _inboxPollTimer = null;
    _activeInboxItem = null;
    await _authorityChanges.close();
  }
}
