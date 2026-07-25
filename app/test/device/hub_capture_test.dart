import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/device.dart';
import 'package:omi/native/native_hub.dart';

Uint64 _u(int value) => Uint64.fromBigInt(BigInt.from(value));

void main() {
  late _CaptureHub hub;
  late HubCapture capture;

  setUp(() {
    hub = _CaptureHub();
    capture = HubCapture(hub, timeout: const Duration(milliseconds: 50));
  });

  tearDown(() {
    capture.dispose();
    hub.eventsController.close();
  });

  group('the seam onto the hub log', () {
    test('opening reports the directory the hub settled on', () async {
      expect(await capture.open(directory: '/tmp/.omi'), isTrue);
      expect(capture.durable, isTrue);
      expect(capture.directory, '/tmp/.omi/capture-wal');
      expect(hub.opens.single, '/tmp/.omi');
    });

    test('a log that could not be opened is reported, not thrown', () async {
      hub.openError = 'Read-only file system';

      expect(await capture.open(directory: '/tmp/.omi'), isFalse);
      expect(capture.durable, isFalse);
      expect(capture.lastError, 'Read-only file system');
    });

    test('a segment reports the idempotency key the hub minted', () async {
      expect(
        await capture.beginSegment(
          deviceId: 'omi-1',
          audioStreamId: 'stream-1',
          encoding: AudioEncoding.opus,
          sampleRateHz: 16000,
          channels: 1,
          gapBefore: true,
        ),
        'segment-0',
      );
      expect(hub.segments.single.gapBefore, isTrue);
      expect(hub.segments.single.encoding, AudioEncoding.opus);
    });

    test('an append resolves only once the hub has answered', () async {
      hub.deferAppends = true;
      var landed = false;
      final pending = capture
          .append(Uint8List.fromList([1, 2, 3]))
          .then((_) => landed = true);

      await Future<void>.delayed(Duration.zero);
      expect(
        landed,
        isFalse,
        reason: 'disk first is only disk first if the caller waits for it',
      );
      hub.releaseAppends();
      await pending;
      expect(landed, isTrue);
      expect(hub.appends.single, [1, 2, 3]);
    });

    test('a reply that never comes releases the caller anyway', () async {
      hub.deferAppends = true;

      await capture.append(Uint8List.fromList([1]));

      // No acknowledgement was ever sent; the timeout is what stops a dropped
      // reply from stopping capture.
      expect(hub.appends, hasLength(1));
    });

    test('a failed append is surfaced without being retried', () async {
      hub.appendError = 'No space left on device';

      await capture.append(Uint8List.fromList([1]));

      expect(capture.lastError, 'No space left on device');
      expect(hub.appends, hasLength(1));
    });
  });

  group('what is waiting to upload', () {
    test('sealing publishes the pending count', () async {
      hub.pendingSegments = 3;

      await capture.seal();

      expect(capture.pendingListenable.value, 3);
    });

    test('a drain reports how many segments left the log', () async {
      hub.pendingSegments = 1;
      hub.uploaded = 4;

      expect(await capture.drain(), 4);
      expect(capture.pendingListenable.value, 1);
    });

    test("the hub's own tick updates the count with nobody asking", () async {
      hub.eventsController.add(
        NativeEventCaptureWalState(
          value: CaptureWalState(
            requestId: '',
            pendingSegments: _u(7),
            pendingBytes: _u(2048),
            uploaded: _u(0),
            lastError: 'offline',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(capture.pendingListenable.value, 7);
      expect(capture.lastError, 'offline');
    });
  });

  group('recorded discontinuities', () {
    test('both sides of a gap round trip', () async {
      await capture.recordGap(
        deviceId: 'omi-1',
        reason: 'packetDiscontinuity',
        endedAt: DateTime.utc(2026, 7, 23, 9, 15),
        endedStreamId: 'stream-1',
      );
      await capture.recordResume(
        deviceId: 'omi-1',
        at: DateTime.utc(2026, 7, 23, 9, 16),
        streamId: 'stream-2',
      );

      final gaps = await capture.readGaps();
      expect(gaps, hasLength(1));
      expect(gaps.single.endedAt, DateTime.utc(2026, 7, 23, 9, 15));
      expect(gaps.single.resumedStreamId, 'stream-2');
      expect(gaps.single.duration, const Duration(minutes: 1));
    });

    test('the resumed stream is never the interrupted one', () {
      final gap =
          CaptureGap(
            deviceId: 'omi-1',
            reason: 'packetDiscontinuity',
            endedAtMs: 1000,
            endedStreamId: 'stream-1',
          ).resumed(
            at: DateTime.fromMillisecondsSinceEpoch(4000, isUtc: true),
            streamId: 'stream-2',
          );

      expect(gap.endedStreamId, isNot(gap.resumedStreamId));
      expect(
        gap.resumedAt,
        DateTime.fromMillisecondsSinceEpoch(4000, isUtc: true),
      );
      expect(gap.duration, const Duration(seconds: 3));
    });
  });

  test('a hub that is not available is a silent no-op', () async {
    final unavailable = HubCapture(_CaptureHub(available: false));
    addTearDown(unavailable.dispose);

    expect(await unavailable.open(directory: '/tmp/.omi'), isFalse);
    expect(
      await unavailable.beginSegment(
        deviceId: 'omi-1',
        audioStreamId: 'stream-1',
        encoding: AudioEncoding.opus,
        sampleRateHz: 16000,
        channels: 1,
      ),
      isNull,
    );
    await unavailable.append(Uint8List.fromList([1]));
    expect(await unavailable.drain(), 0);
    expect(await unavailable.readGaps(), isEmpty);
    expect(unavailable.lastError, isNull);
  });

  test('a disposed seam stops answering rather than throwing', () async {
    capture.dispose();

    expect(await capture.drain(), 0);
    await capture.append(Uint8List.fromList([1]));
    expect(hub.appends, isEmpty);
  });
}

final class _CaptureHub with NativeHubWithoutCapture implements NativeHub {
  _CaptureHub({this.available = true});

  @override
  final bool available;

  @override
  void rewind({required String requestId, required RewindRequest request}) {}

  final eventsController = StreamController<NativeEvent>.broadcast(sync: true);
  final opens = <String>[];
  final appends = <List<int>>[];
  final segments =
      <({String audioStreamId, AudioEncoding encoding, bool gapBefore})>[];
  final gaps = <CaptureGap>[];

  String? openError;
  String? appendError;
  bool deferAppends = false;
  int pendingSegments = 0;
  int uploaded = 0;
  final _deferred = <String>[];

  @override
  Stream<NativeEvent> get events => eventsController.stream;

  @override
  void openCaptureWal({
    required String requestId,
    required String directory,
    int? maxBytes,
    int? maxAgeMs,
    int? maxSegmentBytes,
  }) {
    opens.add(directory);
    eventsController.add(
      NativeEventCaptureWalOpened(
        value: CaptureWalOpened(
          requestId: requestId,
          directory: openError == null ? '$directory/capture-wal' : null,
          error: openError,
        ),
      ),
    );
  }

  @override
  void beginCaptureSegment({
    required String requestId,
    required String deviceId,
    required String audioStreamId,
    required AudioEncoding encoding,
    required int sampleRateHz,
    required int channels,
    bool gapBefore = false,
  }) {
    segments.add((
      audioStreamId: audioStreamId,
      encoding: encoding,
      gapBefore: gapBefore,
    ));
    eventsController.add(
      NativeEventCaptureSegmentBegun(
        value: CaptureSegmentBegun(
          requestId: requestId,
          segmentId: 'segment-${segments.length - 1}',
        ),
      ),
    );
  }

  @override
  void appendCaptureAudio({
    required String requestId,
    required Uint8List bytes,
  }) {
    appends.add(bytes);
    if (deferAppends) {
      _deferred.add(requestId);
      return;
    }
    _acknowledge(requestId);
  }

  void releaseAppends() {
    for (final requestId in _deferred) {
      _acknowledge(requestId);
    }
    _deferred.clear();
  }

  void _acknowledge(String requestId) => eventsController.add(
    NativeEventCaptureAudioAppended(
      value: CaptureAudioAppended(requestId: requestId, error: appendError),
    ),
  );

  @override
  void sealCaptureSegment(String requestId) => _state(requestId);

  @override
  void drainCaptureWal(String requestId) => _state(requestId);

  @override
  void readCaptureWalState(String requestId) => _state(requestId);

  @override
  void closeCaptureWal(String requestId) => _state(requestId);

  void _state(String requestId) => eventsController.add(
    NativeEventCaptureWalState(
      value: CaptureWalState(
        requestId: requestId,
        pendingSegments: _u(pendingSegments),
        pendingBytes: _u(0),
        uploaded: _u(uploaded),
      ),
    ),
  );

  @override
  void recordCaptureGap({
    required String requestId,
    required String deviceId,
    required String reason,
    required int endedAtMs,
    required String endedStreamId,
  }) => gaps.add(
    CaptureGap(
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
  }) {
    for (var index = gaps.length - 1; index >= 0; index--) {
      if (gaps[index].deviceId == deviceId && gaps[index].resumedAtMs == null) {
        gaps[index] = gaps[index].resumed(
          at: DateTime.fromMillisecondsSinceEpoch(atMs, isUtc: true),
          streamId: streamId,
        );
        return;
      }
    }
  }

  @override
  void readCaptureGaps(String requestId) => eventsController.add(
    NativeEventCaptureGaps(
      value: CaptureGaps(requestId: requestId, gaps: List.of(gaps)),
    ),
  );

  @override
  void dispose() {}

  @override
  Future<void> initialize() async {}

  @override
  void cancel(String requestId) {}

  @override
  void sendAudio({
    required String requestId,
    required int sequence,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
    required bool endOfStream,
    required Uint8List bytes,
  }) {}

  @override
  void configureMemory({
    required String requestId,
    required String databasePath,
    required String tenantId,
    required String personId,
  }) {}

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
  }) {}

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  }) {}

  @override
  void exportMemory({
    required String requestId,
    int afterCommit = 0,
    int afterEventIndex = -1,
    int? highWaterMark,
    int limit = 100,
  }) {}

  @override
  void applyMemory({
    required String requestId,
    required List<MemoryApplyCommit> commits,
  }) {}

  @override
  void listMemoryItems({required String requestId, int limit = 50}) {}

  @override
  void correctMemory({
    required String requestId,
    required String claimId,
    required String text,
    required String value,
    required int occurredAtMs,
    required int recordedAtMs,
  }) {}

  @override
  void deleteMemorySource({
    required String requestId,
    required String sourceId,
    required int deletedAtMs,
  }) {}

  @override
  void sendMessage({
    required String requestId,
    required String text,
    String? conversationId,
    String? memoryContext,
    MessageOrigin? origin,
  }) {}

  @override
  void decideApproval({
    required String requestId,
    required String proposalId,
    required ApprovalDecision decision,
    ComputerUseAuthorityReceipt? authorityReceipt,
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

  @override
  void configureTrustedAssistant({
    required String requestId,
    required String managedWorkerOrigin,
  }) {}

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
  }) {}

  @override
  void stopTranscription({
    required String requestId,
    required String audioStreamId,
  }) {}

  @override
  void startLiveVoice({
    required String requestId,
    required String liveStreamId,
    required String ephemeralToken,
    required String model,
    String? resumptionHandle,
    String? sessionContext,
  }) {}

  @override
  void stopLiveVoice({
    required String requestId,
    required String liveStreamId,
  }) {}

  @override
  void updateLiveVoiceContext({
    required String requestId,
    required String liveStreamId,
    required String sessionContext,
  }) {}

  @override
  void startMeeting({required String requestId, String? title}) {}

  @override
  void stopMeeting(String requestId) {}

  @override
  void jotMeetingNote({required String requestId, required String text}) {}

  @override
  void provideMeetingAuth({
    required String requestId,
    required TranscriptionAuth auth,
    String? trustedWorkerOrigin,
  }) {}

  @override
  void setSystemAudioCaptureMode({
    required String requestId,
    required SystemAudioCaptureMode mode,
  }) {}

  @override
  void scanOnboarding({
    required String requestId,
    required List<String> roots,
    required bool includeAppleNotes,
    required bool includeAppleMail,
    required int recordedAtMs,
  }) {}

  @override
  void composeBrief({
    required String requestId,
    required String nowLocal,
    required List<BriefItem> items,
  }) {}

  @override
  void joinCall({
    required String requestId,
    required String link,
    required String ephemeralToken,
    required String model,
    String? displayName,
    bool video = true,
  }) {}

  @override
  void resolveDevAssistant(String requestId) {}
}
