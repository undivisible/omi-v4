import 'dart:async';
import 'dart:typed_data';

import '../native/generated/signals/signals.dart'
    show MemoryItems, NativeEventMemoryItems;
import '../native/native_hub.dart';
import 'demo_seed.dart';

/// The seeded stand-in for the Rust hub, used only by the public demo build.
///
/// It answers the requests that carry the demo's content — memory, the brief,
/// and one scripted assistant turn per message — entirely in this isolate. It
/// deliberately does **not** pretend to do anything it could not do in a
/// browser: capture, the pendant, transcription, live voice, meetings,
/// computer-use approvals and the workspace scan all throw
/// [NativeHubUnavailable] exactly as [UnavailableNativeHub] does on the web
/// target, so those surfaces show their real unavailable state.
final class DemoNativeHub implements NativeHub {
  DemoNativeHub();

  static const _reason =
      'This is the Omi demo running in a browser. Capture, the pendant, '
      'transcription and computer use need the desktop app.';

  final _events = StreamController<NativeEvent>.broadcast();
  final _pending = <String, Timer>{};

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {}

  Never _unavailable() => throw const NativeHubUnavailable(_reason);

  void _emit(NativeEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  void _later(String requestId, Duration delay, void Function() body) {
    _pending[requestId]?.cancel();
    _pending[requestId] = Timer(delay, () {
      _pending.remove(requestId);
      body();
    });
  }

  // ---------------------------------------------------------------- answered

  @override
  void configureMemory({
    required String requestId,
    required String databasePath,
    required String tenantId,
    required String personId,
  }) {}

  @override
  void setSystemAudioCaptureMode({
    required String requestId,
    required SystemAudioCaptureMode mode,
  }) {}

  @override
  void configureTrustedAssistant({
    required String requestId,
    required String managedWorkerOrigin,
  }) {}

  @override
  void configureAssistant({
    required String requestId,
    required AssistantProvider provider,
    required String model,
    required String credential,
    String? endpoint,
  }) {}

  @override
  void clearAssistant(String requestId) {}

  /// The demo has a "key" so the app takes its no-account local path, which is
  /// what puts the real hub UI on screen without a sign-in. It is a marker,
  /// not a credential: [sendMessage] never calls a model with it.
  @override
  void resolveDevAssistant(String requestId) => _later(
    requestId,
    Duration.zero,
    () => _emit(
      NativeEventDevAssistantResolved(
        value: DevAssistant(
          requestId: requestId,
          credential: 'omi-demo-seeded-no-model',
          liveModel: '',
          missingKeyHint: '',
        ),
      ),
    ),
  );

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  }) => _later(
    requestId,
    const Duration(milliseconds: 40),
    () => _emit(
      NativeEventMemorySearchResults(
        value: MemorySearchResults(
          requestId: requestId,
          query: query,
          items: demoMemorySearch(query, limit),
          gaps: demoMemoryGaps,
        ),
      ),
    ),
  );

  @override
  void listMemoryItems({required String requestId, int limit = 50}) => _later(
    requestId,
    const Duration(milliseconds: 40),
    () => _emit(
      NativeEventMemoryItems(
        value: MemoryItems(
          requestId: requestId,
          items: demoMemoryItems().take(limit).toList(),
        ),
      ),
    ),
  );

  /// The hand-built brief stands: a null `crepus` is the documented way to
  /// say "nothing composed", and composing one would need a model.
  @override
  void composeBrief({
    required String requestId,
    required String nowLocal,
    required List<BriefItem> items,
  }) => _later(
    requestId,
    const Duration(milliseconds: 20),
    () => _emit(
      NativeEventBriefComposed(value: BriefComposed(requestId: requestId)),
    ),
  );

  /// One scripted turn, streamed a clause at a time so the chat behaves the
  /// way it does against the real hub. No request leaves the page.
  @override
  void sendMessage({
    required String requestId,
    required String text,
    String? conversationId,
    String? memoryContext,
    MessageOrigin? origin,
  }) {
    final reply = demoReplyFor(text);
    final chunks = _chunk(reply);
    var index = 0;
    void step() {
      if (_events.isClosed) return;
      final last = index == chunks.length - 1;
      _emit(
        NativeEventAssistantDelta(
          value: AssistantDelta(
            requestId: requestId,
            text: chunks[index],
            finalSegment: last,
          ),
        ),
      );
      index += 1;
      if (last) return;
      _later(requestId, const Duration(milliseconds: 55), step);
    }

    _later(requestId, const Duration(milliseconds: 320), step);
  }

  static List<String> _chunk(String reply) {
    final words = reply.split(' ');
    final chunks = <String>[];
    for (var i = 0; i < words.length; i += 4) {
      final slice = words.skip(i).take(4).join(' ');
      chunks.add(i == 0 ? slice : ' $slice');
    }
    return chunks.isEmpty ? [reply] : chunks;
  }

  @override
  void cancel(String requestId) {
    _pending.remove(requestId)?.cancel();
  }

  @override
  void dispose() {
    for (final timer in _pending.values) {
      timer.cancel();
    }
    _pending.clear();
    unawaited(_events.close());
  }

  // ------------------------------------------------------------- unavailable

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
  void exportMemory({
    required String requestId,
    int afterCommit = 0,
    int afterEventIndex = -1,
    int? highWaterMark,
    int limit = 100,
  }) => _unavailable();

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
  void startLiveVoice({
    required String requestId,
    required String liveStreamId,
    required String ephemeralToken,
    required String model,
    String? resumptionHandle,
  }) => _unavailable();

  @override
  void stopLiveVoice({
    required String requestId,
    required String liveStreamId,
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
  void joinCall({
    required String requestId,
    required String link,
    required String ephemeralToken,
    required String model,
    String? displayName,
    bool video = true,
  }) => _unavailable();
}
