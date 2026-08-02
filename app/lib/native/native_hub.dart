import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:rinf/rinf.dart';

import 'generated/signals/signals.dart';

export 'generated/signals/signals.dart'
    show
        AudioEncoding,
        CaptureSource,
        ComputerUseAuthorityReceipt,
        ActionRisk,
        ActionProposal,
        ApprovalDecision,
        ApprovalDecisionAcknowledgement,
        AssistantDelta,
        AssistantProvider,
        BriefComposed,
        BriefItem,
        CallPhase,
        CallState,
        NativeEventBriefComposed,
        DevAssistant,
        NativeEventCallState,
        NativeEventDevAssistantResolved,
        MessageOrigin,
        NativeEvent,
        NativeEventRewind,
        RewindDirective,
        RewindDirectiveDiscard,
        RewindDirectiveEncode,
        RewindDirectiveIdle,
        RewindDirectivePreview,
        RewindDirectiveStored,
        RewindDisplay,
        RewindFrameRecord,
        RewindPayload,
        RewindPayloadDirective,
        RewindPayloadFrames,
        RewindPayloadStatus,
        RewindPayloadUnavailable,
        RewindRequest,
        RewindRequestAllowBundleId,
        RewindRequestDeleteAll,
        RewindRequestDeleteFrame,
        RewindRequestDeleteLast,
        RewindRequestDenyBundleId,
        RewindRequestFrameEncoded,
        RewindRequestListFrames,
        RewindRequestOpen,
        RewindRequestPreviewTaken,
        RewindRequestSearch,
        RewindRequestSetEnabled,
        RewindRequestSetPaused,
        RewindRequestSetPrivacyFlags,
        RewindRequestSetRetention,
        RewindRequestStatus,
        RewindRequestTick,
        RewindRetentionOption,
        RewindSkipReason,
        RewindStatus,
        RewindUpdate,
        RewindWindowContext,
        NativeEventActionProposal,
        NativeEventApprovalDecisionAcknowledged,
        NativeEventAssistantDelta,
        NativeEventError,
        NativeEventMemoryCaptured,
        NativeEventMemoryItems,
        MemoryItem,
        MemoryItems,
        NativeEventMemorySearchResults,
        MemorySearchResults,
        MemorySearchItem,
        NativeEventMemoryApplied,
        MemoryApplied,
        MemoryApplyCommit,
        NativeEventOnboardingScanCompleted,
        NativeEventRuntimeStatus,
        OnboardingScanCompleted,
        OnboardingScanSource,
        OnboardingScanState,
        MeetingCompleted,
        MeetingInsight,
        MeetingStateChanged,
        MeetingTranscriptTurn,
        NativeEventMeetingCompleted,
        NativeEventMeetingInsight,
        NativeEventMeetingStateChanged,
        NativeEventMeetingTranscriptTurn,
        SpeechProfileMatched,
        NativeEventSpeechProfileMatched,
        LiveVoiceAudio,
        LiveVoicePhase,
        LiveVoiceState,
        LiveVoiceTranscript,
        NativeEventLiveVoiceAudio,
        NativeEventLiveVoiceState,
        NativeEventLiveVoiceTranscript,
        SystemAudioCaptureMode,
        NativeEventSpeechProfiles,
        SpeechProfilePayload,
        SpeechProfilePayloadProfiles,
        SpeechProfilePayloadUnavailable,
        SpeechProfileRecord,
        SpeechProfileScope,
        SpeechProfileUpdate,
        CaptureGap,
        CaptureGaps,
        CaptureAudioAppended,
        CaptureSegmentBegun,
        CaptureWalOpened,
        CaptureWalState,
        NativeEventCaptureAudioAppended,
        NativeEventCaptureGaps,
        NativeEventCaptureSegmentBegun,
        NativeEventCaptureWalOpened,
        NativeEventCaptureWalState,
        NativeEventTranscriptGap,
        NativeEventToolProgress,
        NativeEventTranscriptDelta,
        NativeEventTranscriptionStatus,
        NativeEventTranscriptionStopAcknowledged,
        TranscriptionAuth,
        TranscriptionAuthByok,
        TranscriptionAuthLocal,
        TranscriptionAuthManaged,
        TranscriptionRoute,
        TranscriptionState,
        TranscriptionStatus,
        TranscriptionStopAcknowledgement,
        TranscriptGap,
        TranscriptLocator,
        ToolProgress,
        ToolStatus,
        TranscriptDelta;
export 'generated/signals/signals.dart' show Uint64;

const _sttTempo = int.fromEnvironment('OMI_STT_TEMPO', defaultValue: 1);

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

  /// Folds the memory captured before anyone signed in into the account the
  /// hub is configured for. Answered by one `ToolProgress` named
  /// `local-memory`, whose `detail` is set only when memory actually moved.
  void absorbLocalMemory({
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
    required int recordedAtMs,
    String? text,
    String? application,
    String? windowTitle,
    TranscriptLocator? transcriptLocator,
  });
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  });
  void exportMemory({
    required String requestId,
    int afterCommit = 0,
    int afterEventIndex = -1,
    int? highWaterMark,
    int limit = 100,
  });
  void applyMemory({
    required String requestId,
    required List<MemoryApplyCommit> commits,
    bool applyDeletions = false,
  });
  void listMemoryItems({required String requestId, int limit = 50});
  void correctMemory({
    required String requestId,
    required String claimId,
    required String text,
    required String value,
    required int occurredAtMs,
    required int recordedAtMs,
  });
  void deleteMemorySource({
    required String requestId,
    required String sourceId,
    required int deletedAtMs,
  });
  void sendMessage({
    required String requestId,
    required String text,
    String? conversationId,
    String? memoryContext,
    MessageOrigin? origin,
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
  void configureCloudMemory({
    required String requestId,
    required String managedWorkerOrigin,
    required String credential,
  });
  void configureSpeechProfiles({
    required String requestId,
    SpeechProfileScope? scope,
  });

  /// Asks for every speech profile in [scope]. The answer arrives as a
  /// `NativeEventSpeechProfiles` carrying the same [requestId].
  void listSpeechProfiles({
    required String requestId,
    required SpeechProfileScope scope,
  });

  /// Names [profileId], or clears its name when [displayName] is null.
  void renameSpeechProfile({
    required String requestId,
    required SpeechProfileScope scope,
    required String profileId,
    String? displayName,
  });

  /// Folds [sourceProfileId] into [targetProfileId], tombstoning the source.
  void mergeSpeechProfiles({
    required String requestId,
    required SpeechProfileScope scope,
    required String targetProfileId,
    required String sourceProfileId,
  });

  /// Deletes every voiceprint held for [profileId].
  void forgetSpeechProfile({
    required String requestId,
    required SpeechProfileScope scope,
    required String profileId,
  });

  /// Stops or resumes learning new voiceprints for [profileId].
  void pauseSpeechLearning({
    required String requestId,
    required SpeechProfileScope scope,
    required String profileId,
    required bool paused,
  });
  void clearAssistant(String requestId);
  void decideApproval({
    required String requestId,
    required String proposalId,
    required ApprovalDecision decision,
    ComputerUseAuthorityReceipt? authorityReceipt,
  });
  void startTranscription({
    required String requestId,
    required String audioStreamId,
    required String deviceId,
    required TranscriptionAuth auth,
    required String language,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
  });
  void stopTranscription({
    required String requestId,
    required String audioStreamId,
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
  void startLiveVoice({
    required String requestId,
    required String liveStreamId,
    required String ephemeralToken,
    required String model,
    String? resumptionHandle,
    String? sessionContext,
  });
  void stopLiveVoice({required String requestId, required String liveStreamId});
  void updateLiveVoiceContext({
    required String requestId,
    required String liveStreamId,
    required String sessionContext,
  });
  void startMeeting({required String requestId, String? title});
  void stopMeeting(String requestId);
  void jotMeetingNote({required String requestId, required String text});
  void provideMeetingAuth({
    required String requestId,
    required TranscriptionAuth auth,
    String? trustedWorkerOrigin,
  });
  void setSystemAudioCaptureMode({
    required String requestId,
    required SystemAudioCaptureMode mode,
  });
  void scanOnboarding({
    required String requestId,
    required List<String> roots,
    required bool includeAppleNotes,
    required bool includeAppleMail,
    required int recordedAtMs,
  });

  /// Asks the hub to compose the currents brief. Answered by exactly one
  /// [NativeEventBriefComposed]; a null `crepus` there means the hand-built
  /// brief stands.
  void composeBrief({
    required String requestId,
    required String nowLocal,
    required List<BriefItem> items,
  });

  /// Joins a call link and bridges it to a realtime voice session. Progress
  /// arrives as [NativeEventCallState].
  void joinCall({
    required String requestId,
    required String link,
    required String ephemeralToken,
    required String model,
    String? displayName,
    bool video = true,
  });

  /// Opens (creating if needed) the pendant capture write-ahead log under
  /// [directory], the shared `.omi` data directory. Answered by exactly one
  /// [NativeEventCaptureWalOpened]; an `error` there means capture still runs
  /// but nothing is durable, which is reported rather than fatal. Every bound
  /// is optional and omitting one takes the hub's own default.
  void openCaptureWal({
    required String requestId,
    required String directory,
    int? maxBytes,
    int? maxAgeMs,
    int? maxSegmentBytes,
  });

  /// Supplies (or withdraws) the credentials sealed segments are uploaded
  /// with. Either half missing leaves the log holding every segment until it
  /// ages or size-evicts out, which is the only safe answer when nobody is
  /// signed in: audio is never dropped because the route was unreachable.
  void configureCaptureUpload({
    required String requestId,
    String? endpoint,
    String? firebaseToken,
  });

  /// Seals whatever is open and starts a new segment. Answered by exactly one
  /// [NativeEventCaptureSegmentBegun] carrying the id that is the upload's
  /// idempotency key.
  void beginCaptureSegment({
    required String requestId,
    required String deviceId,
    required String audioStreamId,
    required AudioEncoding encoding,
    required int sampleRateHz,
    required int channels,
    bool gapBefore = false,
  });

  /// Appends one decoded frame to the open segment. Answered by exactly one
  /// [NativeEventCaptureAudioAppended], which is what lets the caller put the
  /// frame on disk before it puts the same frame on the transcription socket.
  void appendCaptureAudio({
    required String requestId,
    required Uint8List bytes,
  });
  void importRingRange({
    required String requestId,
    required String sourceId,
    required String deviceId,
    required int startedAtMs,
    required List<Uint8List> frames,
  });

  /// Seals the open segment so it becomes uploadable. Answered by exactly one
  /// [NativeEventCaptureWalState].
  void sealCaptureSegment(String requestId);

  /// Runs one upload pass now. Answered by exactly one
  /// [NativeEventCaptureWalState]; concurrent requests share the pass already
  /// in flight.
  void drainCaptureWal(String requestId);

  /// Reports what the log is holding without uploading anything. Answered by
  /// exactly one [NativeEventCaptureWalState].
  void readCaptureWalState(String requestId);

  /// Seals the open segment and releases the file handle. Answered by exactly
  /// one [NativeEventCaptureWalState].
  void closeCaptureWal(String requestId);

  /// Records that capture stopped. The resume side arrives separately, because
  /// a device that never comes back still has a discontinuity worth showing.
  void recordCaptureGap({
    required String requestId,
    required String deviceId,
    required String reason,
    required int endedAtMs,
    required String endedStreamId,
  });

  /// Attaches the resume side to the most recent open gap for this device.
  /// [streamId] is always the NEW stream, which is what makes the two sides of
  /// the discontinuity impossible to read as one recording.
  void recordCaptureResume({
    required String requestId,
    required String deviceId,
    required int atMs,
    required String streamId,
  });

  /// Answered by exactly one [NativeEventCaptureGaps], oldest first.
  void readCaptureGaps(String requestId);

  /// Resolves the dev-only assistant credential the app falls back to with no
  /// account. Answered by exactly one [NativeEventDevAssistantResolved].
  void resolveDevAssistant(String requestId);

  /// Drives one step of the Rewind capture handshake, or one thing the user
  /// asked the screen-history engine to do. Answered by exactly one
  /// [NativeEventRewind] carrying the same `requestId`.
  void rewind({required String requestId, required RewindRequest request});
  void dispose();
}

/// The capture half of [NativeHub], stubbed out.
///
/// Only the mobile pendant path drives the write-ahead log, so a hub standing
/// in for something else — the demo, a desktop-only build, a test double —
/// implements everything else and mixes this in rather than restating eleven
/// no-ops. Mixing it in is also the honest answer: a hub that cannot capture
/// silently records nothing, which is exactly what [HubCapture] treats as "not
/// durable" rather than as a failure.
mixin NativeHubWithoutCapture implements NativeHub {
  @override
  void configureCloudMemory({
    required String requestId,
    required String managedWorkerOrigin,
    required String credential,
  }) {}

  @override
  void openCaptureWal({
    required String requestId,
    required String directory,
    int? maxBytes,
    int? maxAgeMs,
    int? maxSegmentBytes,
  }) {}

  @override
  void configureCaptureUpload({
    required String requestId,
    String? endpoint,
    String? firebaseToken,
  }) {}

  @override
  void beginCaptureSegment({
    required String requestId,
    required String deviceId,
    required String audioStreamId,
    required AudioEncoding encoding,
    required int sampleRateHz,
    required int channels,
    bool gapBefore = false,
  }) {}

  @override
  void appendCaptureAudio({
    required String requestId,
    required Uint8List bytes,
  }) {}

  @override
  void importRingRange({
    required String requestId,
    required String sourceId,
    required String deviceId,
    required int startedAtMs,
    required List<Uint8List> frames,
  }) {}

  @override
  void sealCaptureSegment(String requestId) {}

  @override
  void drainCaptureWal(String requestId) {}

  @override
  void readCaptureWalState(String requestId) {}

  @override
  void closeCaptureWal(String requestId) {}

  @override
  void recordCaptureGap({
    required String requestId,
    required String deviceId,
    required String reason,
    required int endedAtMs,
    required String endedStreamId,
  }) {}

  @override
  void recordCaptureResume({
    required String requestId,
    required String deviceId,
    required int atMs,
    required String streamId,
  }) {}

  @override
  void readCaptureGaps(String requestId) {}
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
  void absorbLocalMemory({
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
    required int recordedAtMs,
    String? text,
    String? application,
    String? windowTitle,
    TranscriptLocator? transcriptLocator,
  }) => _unavailable();

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  }) => _unavailable();

  @override
  void exportMemory({
    required String requestId,
    int afterCommit = 0,
    int afterEventIndex = -1,
    int? highWaterMark,
    int limit = 100,
  }) => _unavailable();

  @override
  void applyMemory({
    required String requestId,
    required List<MemoryApplyCommit> commits,
    bool applyDeletions = false,
  }) => _unavailable();

  @override
  void listMemoryItems({required String requestId, int limit = 50}) =>
      _unavailable();

  @override
  void correctMemory({
    required String requestId,
    required String claimId,
    required String text,
    required String value,
    required int occurredAtMs,
    required int recordedAtMs,
  }) => _unavailable();

  @override
  void deleteMemorySource({
    required String requestId,
    required String sourceId,
    required int deletedAtMs,
  }) => _unavailable();

  @override
  void scanOnboarding({
    required String requestId,
    required List<String> roots,
    required bool includeAppleNotes,
    required bool includeAppleMail,
    required int recordedAtMs,
  }) => _unavailable();

  @override
  void startLiveVoice({
    required String requestId,
    required String liveStreamId,
    required String ephemeralToken,
    required String model,
    String? resumptionHandle,
    String? sessionContext,
  }) => _unavailable();

  @override
  void stopLiveVoice({
    required String requestId,
    required String liveStreamId,
  }) => _unavailable();

  @override
  void updateLiveVoiceContext({
    required String requestId,
    required String liveStreamId,
    required String sessionContext,
  }) => _unavailable();

  @override
  void sendMessage({
    required String requestId,
    required String text,
    String? conversationId,
    String? memoryContext,
    MessageOrigin? origin,
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
  void configureCloudMemory({
    required String requestId,
    required String managedWorkerOrigin,
    required String credential,
  }) => _unavailable();

  @override
  void configureSpeechProfiles({
    required String requestId,
    SpeechProfileScope? scope,
  }) => _unavailable();

  @override
  void listSpeechProfiles({
    required String requestId,
    required SpeechProfileScope scope,
  }) => _unavailable();

  @override
  void renameSpeechProfile({
    required String requestId,
    required SpeechProfileScope scope,
    required String profileId,
    String? displayName,
  }) => _unavailable();

  @override
  void mergeSpeechProfiles({
    required String requestId,
    required SpeechProfileScope scope,
    required String targetProfileId,
    required String sourceProfileId,
  }) => _unavailable();

  @override
  void forgetSpeechProfile({
    required String requestId,
    required SpeechProfileScope scope,
    required String profileId,
  }) => _unavailable();

  @override
  void pauseSpeechLearning({
    required String requestId,
    required SpeechProfileScope scope,
    required String profileId,
    required bool paused,
  }) => _unavailable();

  @override
  void clearAssistant(String requestId) => _unavailable();

  @override
  void decideApproval({
    required String requestId,
    required String proposalId,
    required ApprovalDecision decision,
    ComputerUseAuthorityReceipt? authorityReceipt,
  }) => _unavailable();

  @override
  void startTranscription({
    required String requestId,
    required String audioStreamId,
    required String deviceId,
    required TranscriptionAuth auth,
    required String language,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
  }) => _unavailable();

  @override
  void stopTranscription({
    required String requestId,
    required String audioStreamId,
  }) => _unavailable();

  @override
  void startMeeting({required String requestId, String? title}) =>
      _unavailable();

  @override
  void stopMeeting(String requestId) => _unavailable();

  @override
  void jotMeetingNote({required String requestId, required String text}) =>
      _unavailable();

  @override
  void provideMeetingAuth({
    required String requestId,
    required TranscriptionAuth auth,
    String? trustedWorkerOrigin,
  }) => _unavailable();

  @override
  void setSystemAudioCaptureMode({
    required String requestId,
    required SystemAudioCaptureMode mode,
  }) => _unavailable();

  @override
  void composeBrief({
    required String requestId,
    required String nowLocal,
    required List<BriefItem> items,
  }) => _unavailable();

  @override
  void joinCall({
    required String requestId,
    required String link,
    required String ephemeralToken,
    required String model,
    String? displayName,
    bool video = true,
  }) => _unavailable();

  @override
  void openCaptureWal({
    required String requestId,
    required String directory,
    int? maxBytes,
    int? maxAgeMs,
    int? maxSegmentBytes,
  }) => _unavailable();

  @override
  void configureCaptureUpload({
    required String requestId,
    String? endpoint,
    String? firebaseToken,
  }) => _unavailable();

  @override
  void beginCaptureSegment({
    required String requestId,
    required String deviceId,
    required String audioStreamId,
    required AudioEncoding encoding,
    required int sampleRateHz,
    required int channels,
    bool gapBefore = false,
  }) => _unavailable();

  @override
  void appendCaptureAudio({
    required String requestId,
    required Uint8List bytes,
  }) => _unavailable();

  @override
  void importRingRange({
    required String requestId,
    required String sourceId,
    required String deviceId,
    required int startedAtMs,
    required List<Uint8List> frames,
  }) => _unavailable();

  @override
  void sealCaptureSegment(String requestId) => _unavailable();

  @override
  void drainCaptureWal(String requestId) => _unavailable();

  @override
  void readCaptureWalState(String requestId) => _unavailable();

  @override
  void closeCaptureWal(String requestId) => _unavailable();

  @override
  void recordCaptureGap({
    required String requestId,
    required String deviceId,
    required String reason,
    required int endedAtMs,
    required String endedStreamId,
  }) => _unavailable();

  @override
  void recordCaptureResume({
    required String requestId,
    required String deviceId,
    required int atMs,
    required String streamId,
  }) => _unavailable();

  @override
  void readCaptureGaps(String requestId) => _unavailable();

  @override
  void resolveDevAssistant(String requestId) => _unavailable();

  @override
  void rewind({required String requestId, required RewindRequest request}) =>
      _unavailable();

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
  void absorbLocalMemory({
    required String requestId,
    required String databasePath,
    required String tenantId,
    required String personId,
  }) => _send(
    requestId,
    CommandAbsorbLocalMemory(
      databasePath: databasePath,
      tenantId: tenantId,
      personId: personId,
    ),
  );

  @override
  void scanOnboarding({
    required String requestId,
    required List<String> roots,
    required bool includeAppleNotes,
    required bool includeAppleMail,
    required int recordedAtMs,
  }) => _send(
    requestId,
    CommandScanOnboarding(
      roots: roots,
      includeAppleNotes: includeAppleNotes,
      includeAppleMail: includeAppleMail,
      recordedAtMs: recordedAtMs,
    ),
  );

  @override
  void capture({
    required String requestId,
    required String ingestionKey,
    required CaptureSource source,
    required int occurredAtMs,
    required int recordedAtMs,
    String? text,
    String? application,
    String? windowTitle,
    TranscriptLocator? transcriptLocator,
  }) => _send(
    requestId,
    CommandCaptureEvent(
      ingestionKey: ingestionKey,
      source: source,
      occurredAtMs: occurredAtMs,
      recordedAtMs: recordedAtMs,
      text: text,
      application: application,
      windowTitle: windowTitle,
      transcriptLocator: transcriptLocator,
    ),
  );

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  }) => _send(
    requestId,
    CommandSearchMemory(
      query: query,
      limit: limit,
      asOfValidAtMs: asOfValidAtMs,
      asOfRecordedAtMs: asOfRecordedAtMs,
    ),
  );

  @override
  void exportMemory({
    required String requestId,
    int afterCommit = 0,
    int afterEventIndex = -1,
    int? highWaterMark,
    int limit = 100,
  }) => _send(
    requestId,
    CommandExportMemory(
      afterCommit: afterCommit,
      afterEventIndex: afterEventIndex,
      highWaterMark: highWaterMark,
      limit: limit,
    ),
  );

  @override
  void applyMemory({
    required String requestId,
    required List<MemoryApplyCommit> commits,
    bool applyDeletions = false,
  }) => _send(
    requestId,
    CommandApplyMemory(commits: commits, applyDeletions: applyDeletions),
  );

  @override
  void listMemoryItems({required String requestId, int limit = 50}) =>
      _send(requestId, CommandListMemoryItems(limit: limit));

  @override
  void correctMemory({
    required String requestId,
    required String claimId,
    required String text,
    required String value,
    required int occurredAtMs,
    required int recordedAtMs,
  }) => _send(
    requestId,
    CommandCorrectMemory(
      claimId: claimId,
      text: text,
      value: value,
      occurredAtMs: occurredAtMs,
      recordedAtMs: recordedAtMs,
    ),
  );

  @override
  void deleteMemorySource({
    required String requestId,
    required String sourceId,
    required int deletedAtMs,
  }) => _send(
    requestId,
    CommandDeleteMemorySource(sourceId: sourceId, deletedAtMs: deletedAtMs),
  );

  @override
  void sendMessage({
    required String requestId,
    required String text,
    String? conversationId,
    String? memoryContext,
    MessageOrigin? origin,
  }) => _send(
    requestId,
    CommandSendMessage(
      text: text,
      conversationId: conversationId,
      memoryContext: memoryContext,
      origin: origin,
    ),
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
  void configureCloudMemory({
    required String requestId,
    required String managedWorkerOrigin,
    required String credential,
  }) => _send(
    requestId,
    CommandConfigureCloudMemory(
      managedWorkerOrigin: managedWorkerOrigin,
      credential: credential,
    ),
  );

  @override
  void configureSpeechProfiles({
    required String requestId,
    SpeechProfileScope? scope,
  }) => _send(requestId, CommandConfigureSpeechProfiles(scope: scope));

  @override
  void listSpeechProfiles({
    required String requestId,
    required SpeechProfileScope scope,
  }) => _send(requestId, CommandListSpeechProfiles(scope: scope));

  @override
  void renameSpeechProfile({
    required String requestId,
    required SpeechProfileScope scope,
    required String profileId,
    String? displayName,
  }) => _send(
    requestId,
    CommandRenameSpeechProfile(
      scope: scope,
      profileId: profileId,
      displayName: displayName,
    ),
  );

  @override
  void mergeSpeechProfiles({
    required String requestId,
    required SpeechProfileScope scope,
    required String targetProfileId,
    required String sourceProfileId,
  }) => _send(
    requestId,
    CommandMergeSpeechProfiles(
      scope: scope,
      targetProfileId: targetProfileId,
      sourceProfileId: sourceProfileId,
    ),
  );

  @override
  void forgetSpeechProfile({
    required String requestId,
    required SpeechProfileScope scope,
    required String profileId,
  }) => _send(
    requestId,
    CommandForgetSpeechProfile(scope: scope, profileId: profileId),
  );

  @override
  void pauseSpeechLearning({
    required String requestId,
    required SpeechProfileScope scope,
    required String profileId,
    required bool paused,
  }) => _send(
    requestId,
    CommandPauseSpeechLearning(
      scope: scope,
      profileId: profileId,
      paused: paused,
    ),
  );

  @override
  void clearAssistant(String requestId) =>
      _send(requestId, const CommandClearAssistant());

  @override
  void decideApproval({
    required String requestId,
    required String proposalId,
    required ApprovalDecision decision,
    ComputerUseAuthorityReceipt? authorityReceipt,
  }) => _send(
    requestId,
    CommandApprovalDecision(
      proposalId: proposalId,
      decision: decision,
      authorityReceipt: authorityReceipt,
    ),
  );

  @override
  void startTranscription({
    required String requestId,
    required String audioStreamId,
    required String deviceId,
    required TranscriptionAuth auth,
    required String language,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
  }) => _send(
    requestId,
    CommandStartTranscription(
      audioStreamId: audioStreamId,
      deviceId: deviceId,
      auth: auth,
      language: language,
      sampleRateHz: sampleRateHz,
      channels: channels,
      encoding: encoding,
      tempo: _sttTempo,
    ),
  );

  @override
  void stopTranscription({
    required String requestId,
    required String audioStreamId,
  }) =>
      _send(requestId, CommandStopTranscription(audioStreamId: audioStreamId));

  @override
  void startLiveVoice({
    required String requestId,
    required String liveStreamId,
    required String ephemeralToken,
    required String model,
    String? resumptionHandle,
    String? sessionContext,
  }) => _send(
    requestId,
    CommandStartLiveVoice(
      liveStreamId: liveStreamId,
      ephemeralToken: ephemeralToken,
      model: model,
      resumptionHandle: resumptionHandle,
      sessionContext: sessionContext,
    ),
  );

  @override
  void stopLiveVoice({
    required String requestId,
    required String liveStreamId,
  }) => _send(requestId, CommandStopLiveVoice(liveStreamId: liveStreamId));

  @override
  void updateLiveVoiceContext({
    required String requestId,
    required String liveStreamId,
    required String sessionContext,
  }) => _send(
    requestId,
    CommandUpdateLiveVoiceContext(
      liveStreamId: liveStreamId,
      sessionContext: sessionContext,
    ),
  );

  @override
  void startMeeting({required String requestId, String? title}) =>
      _send(requestId, CommandStartMeeting(title: title));

  @override
  void stopMeeting(String requestId) =>
      _send(requestId, const CommandStopMeeting());

  @override
  void jotMeetingNote({required String requestId, required String text}) =>
      _send(requestId, CommandJotMeetingNote(text: text));

  @override
  void provideMeetingAuth({
    required String requestId,
    required TranscriptionAuth auth,
    String? trustedWorkerOrigin,
  }) => _send(
    requestId,
    CommandProvideMeetingAuth(
      auth: auth,
      trustedWorkerOrigin: trustedWorkerOrigin,
    ),
  );

  @override
  void setSystemAudioCaptureMode({
    required String requestId,
    required SystemAudioCaptureMode mode,
  }) => _send(requestId, CommandSetSystemAudioCaptureMode(mode: mode));

  @override
  void composeBrief({
    required String requestId,
    required String nowLocal,
    required List<BriefItem> items,
  }) => _send(requestId, CommandComposeBrief(nowLocal: nowLocal, items: items));

  @override
  void joinCall({
    required String requestId,
    required String link,
    required String ephemeralToken,
    required String model,
    String? displayName,
    bool video = true,
  }) => _send(
    requestId,
    CommandJoinCall(
      link: link,
      displayName: displayName,
      video: video,
      ephemeralToken: ephemeralToken,
      model: model,
    ),
  );

  @override
  void openCaptureWal({
    required String requestId,
    required String directory,
    int? maxBytes,
    int? maxAgeMs,
    int? maxSegmentBytes,
  }) => _send(
    requestId,
    CommandOpenCaptureWal(
      directory: directory,
      maxBytes: _unsigned(maxBytes),
      maxAgeMs: maxAgeMs,
      maxSegmentBytes: _unsigned(maxSegmentBytes),
    ),
  );

  @override
  void configureCaptureUpload({
    required String requestId,
    String? endpoint,
    String? firebaseToken,
  }) => _send(
    requestId,
    CommandConfigureCaptureUpload(
      endpoint: endpoint,
      firebaseToken: firebaseToken,
    ),
  );

  @override
  void beginCaptureSegment({
    required String requestId,
    required String deviceId,
    required String audioStreamId,
    required AudioEncoding encoding,
    required int sampleRateHz,
    required int channels,
    bool gapBefore = false,
  }) => _send(
    requestId,
    CommandBeginCaptureSegment(
      deviceId: deviceId,
      audioStreamId: audioStreamId,
      encoding: encoding,
      sampleRateHz: sampleRateHz,
      channels: channels,
      gapBefore: gapBefore,
    ),
  );

  @override
  void appendCaptureAudio({
    required String requestId,
    required Uint8List bytes,
  }) => _send(requestId, CommandAppendCaptureAudio(bytes: bytes));

  @override
  void importRingRange({
    required String requestId,
    required String sourceId,
    required String deviceId,
    required int startedAtMs,
    required List<Uint8List> frames,
  }) => _send(
    requestId,
    CommandImportRingRange(
      sourceId: sourceId,
      deviceId: deviceId,
      startedAtMs: startedAtMs,
      frames: frames,
    ),
  );

  @override
  void sealCaptureSegment(String requestId) =>
      _send(requestId, const CommandSealCaptureSegment());

  @override
  void drainCaptureWal(String requestId) =>
      _send(requestId, const CommandDrainCaptureWal());

  @override
  void readCaptureWalState(String requestId) =>
      _send(requestId, const CommandReadCaptureWalState());

  @override
  void closeCaptureWal(String requestId) =>
      _send(requestId, const CommandCloseCaptureWal());

  @override
  void recordCaptureGap({
    required String requestId,
    required String deviceId,
    required String reason,
    required int endedAtMs,
    required String endedStreamId,
  }) => _send(
    requestId,
    CommandRecordCaptureGap(
      deviceId: deviceId,
      reason: reason,
      endedAtMs: endedAtMs,
      endedStreamId: endedStreamId,
    ),
  );

  @override
  void recordCaptureResume({
    required String requestId,
    required String deviceId,
    required int atMs,
    required String streamId,
  }) => _send(
    requestId,
    CommandRecordCaptureResume(
      deviceId: deviceId,
      atMs: atMs,
      streamId: streamId,
    ),
  );

  @override
  void readCaptureGaps(String requestId) =>
      _send(requestId, const CommandReadCaptureGaps());

  /// The generated bridge types carry Rust's `u64` as a [Uint64], so a bound
  /// the caller expressed as a plain Dart int is widened here rather than at
  /// every call site.
  static Uint64? _unsigned(int? value) =>
      value == null ? null : Uint64.fromBigInt(BigInt.from(value));

  @override
  void resolveDevAssistant(String requestId) =>
      _send(requestId, const CommandResolveDevAssistant());

  @override
  void rewind({required String requestId, required RewindRequest request}) =>
      _send(requestId, CommandRewind(request: request));

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
