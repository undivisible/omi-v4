import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:rinf/rinf.dart';

import 'generated/signals/signals.dart';

export 'generated/signals/signals.dart'
    show
        AudioEncoding,
        CaptureSource,
        ActionProposal,
        ApprovalDecision,
        AssistantDelta,
        AssistantProvider,
        NativeEvent,
        NativeEventActionProposal,
        NativeEventAssistantDelta,
        NativeEventError,
        NativeEventMemoryCaptured,
        NativeEventToolProgress,
        NativeEventTranscriptDelta,
        ToolProgress,
        ToolStatus,
        TranscriptDelta;

abstract interface class NativeHub {
  bool get available;
  Stream<NativeEvent> get events;

  Future<void> initialize();
  void configureMemory({
    required String requestId,
    required String databasePath,
    required String tenantId,
    required String personId,
  });
  void capture({
    required String requestId,
    required String ingestionKey,
    required CaptureSource source,
    required int occurredAtMs,
    String? text,
    String? application,
    String? windowTitle,
  });
  void search({
    required String requestId,
    required String query,
    int limit = 12,
  });
  void sendMessage({
    required String requestId,
    required String text,
    String? conversationId,
  });
  void configureAssistant({
    required String requestId,
    required AssistantProvider provider,
    required String model,
    required String credential,
    String? endpoint,
  });
  void configureTrustedAssistant({
    required String requestId,
    required String managedWorkerOrigin,
  });
  void clearAssistant(String requestId);
  void decideApproval({
    required String requestId,
    required String proposalId,
    required ApprovalDecision decision,
  });
  void cancel(String requestId);
  void sendAudio({
    required String requestId,
    required int sequence,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
    required bool endOfStream,
    required Uint8List bytes,
  });
  void dispose();
}

NativeHub createNativeHub() => kIsWeb
    ? const UnavailableNativeHub('Native capture is unavailable on web.')
    : RinfNativeHub();

final class NativeHubUnavailable implements Exception {
  const NativeHubUnavailable(this.message);

  final String message;

  @override
  String toString() => 'NativeHubUnavailable: $message';
}

final class UnavailableNativeHub implements NativeHub {
  const UnavailableNativeHub(this.reason);

  final String reason;

  @override
  bool get available => false;

  @override
  Stream<NativeEvent> get events => const Stream.empty();

  @override
  Future<void> initialize() async {}

  Never _unavailable() => throw NativeHubUnavailable(reason);

  @override
  void configureMemory({
    required String requestId,
    required String databasePath,
    required String tenantId,
    required String personId,
  }) => _unavailable();

  @override
  void capture({
    required String requestId,
    required String ingestionKey,
    required CaptureSource source,
    required int occurredAtMs,
    String? text,
    String? application,
    String? windowTitle,
  }) => _unavailable();

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
  }) => _unavailable();

  @override
  void sendMessage({
    required String requestId,
    required String text,
    String? conversationId,
  }) => _unavailable();

  @override
  void configureAssistant({
    required String requestId,
    required AssistantProvider provider,
    required String model,
    required String credential,
    String? endpoint,
  }) => _unavailable();

  @override
  void configureTrustedAssistant({
    required String requestId,
    required String managedWorkerOrigin,
  }) => _unavailable();

  @override
  void clearAssistant(String requestId) => _unavailable();

  @override
  void decideApproval({
    required String requestId,
    required String proposalId,
    required ApprovalDecision decision,
  }) => _unavailable();

  @override
  void cancel(String requestId) => _unavailable();

  @override
  void sendAudio({
    required String requestId,
    required int sequence,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
    required bool endOfStream,
    required Uint8List bytes,
  }) => _unavailable();

  @override
  void dispose() {}
}

final class RinfNativeHub implements NativeHub {
  bool _initialized = false;

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events =>
      NativeEvent.rustSignalStream.map((pack) => pack.message);

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await initializeRust(assignRustSignal);
    _initialized = true;
  }

  void _send(String requestId, Command command) {
    if (!_initialized) {
      throw const NativeHubUnavailable('Native hub is not initialized.');
    }
    ClientCommand(requestId: requestId, command: command).sendSignalToRust();
  }

  @override
  void configureMemory({
    required String requestId,
    required String databasePath,
    required String tenantId,
    required String personId,
  }) => _send(
    requestId,
    CommandConfigureMemory(
      databasePath: databasePath,
      tenantId: tenantId,
      personId: personId,
    ),
  );

  @override
  void capture({
    required String requestId,
    required String ingestionKey,
    required CaptureSource source,
    required int occurredAtMs,
    String? text,
    String? application,
    String? windowTitle,
  }) => _send(
    requestId,
    CommandCaptureEvent(
      ingestionKey: ingestionKey,
      source: source,
      occurredAtMs: occurredAtMs,
      text: text,
      application: application,
      windowTitle: windowTitle,
    ),
  );

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
  }) => _send(requestId, CommandSearchMemory(query: query, limit: limit));

  @override
  void sendMessage({
    required String requestId,
    required String text,
    String? conversationId,
  }) => _send(
    requestId,
    CommandSendMessage(text: text, conversationId: conversationId),
  );

  @override
  void configureAssistant({
    required String requestId,
    required AssistantProvider provider,
    required String model,
    required String credential,
    String? endpoint,
  }) => _send(
    requestId,
    CommandConfigureAssistant(
      provider: provider,
      model: model,
      endpoint: endpoint,
      credential: credential,
    ),
  );

  @override
  void configureTrustedAssistant({
    required String requestId,
    required String managedWorkerOrigin,
  }) => _send(
    requestId,
    CommandConfigureTrustedAssistant(managedWorkerOrigin: managedWorkerOrigin),
  );

  @override
  void clearAssistant(String requestId) =>
      _send(requestId, const CommandClearAssistant());

  @override
  void decideApproval({
    required String requestId,
    required String proposalId,
    required ApprovalDecision decision,
  }) => _send(
    requestId,
    CommandApprovalDecision(proposalId: proposalId, decision: decision),
  );

  @override
  void cancel(String requestId) => _send(requestId, const CommandCancel());

  @override
  void sendAudio({
    required String requestId,
    required int sequence,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
    required bool endOfStream,
    required Uint8List bytes,
  }) {
    if (!_initialized) {
      throw const NativeHubUnavailable('Native hub is not initialized.');
    }
    if (sequence < 0) throw RangeError.value(sequence, 'sequence');
    AudioChunk(
      requestId: requestId,
      sequence: Uint64.fromBigInt(BigInt.from(sequence)),
      sampleRateHz: sampleRateHz,
      channels: channels,
      encoding: encoding,
      endOfStream: endOfStream,
    ).sendSignalToRust(bytes);
  }

  @override
  void dispose() {
    if (!_initialized) return;
    finalizeRust();
    _initialized = false;
  }
}
