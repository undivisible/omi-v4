import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/native/generated/signals/signals.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  test('generated native command contract round trips', () {
    final commands = <Command>[
      const CommandConfigureMemory(
        databasePath: '/tmp/omi.db',
        tenantId: 'tenant',
        personId: 'person',
      ),
      const CommandConfigureAssistant(
        provider: AssistantProvider.worker,
        model: 'managed-chat',
        endpoint: 'https://assistant.example.test/v1',
        credential: 'runtime-token',
      ),
      const CommandConfigureTrustedAssistant(
        managedWorkerOrigin: 'https://assistant.example.test',
      ),
      const CommandClearAssistant(),
      const CommandCaptureEvent(
        ingestionKey: 'stable-capture',
        source: CaptureSource.screen,
        occurredAtMs: 42,
        recordedAtMs: 45,
        text: 'remember this',
      ),
      const CommandSearchMemory(
        query: 'this',
        limit: 12,
        asOfValidAtMs: 42,
        asOfRecordedAtMs: 45,
      ),
      const CommandExportMemory(
        afterCommit: 0,
        afterEventIndex: -1,
        limit: 100,
      ),
      const CommandListMemoryItems(limit: 50),
      const CommandCorrectMemory(
        claimId: 'claim-1',
        text: 'I moved to Beta',
        value: 'Beta',
        occurredAtMs: 43,
        recordedAtMs: 46,
      ),
      const CommandDeleteMemorySource(sourceId: 'source-1', deletedAtMs: 44),
      const CommandApprovalDecision(
        proposalId: 'proposal-1',
        decision: ApprovalDecision.approveOnce,
      ),
      const CommandCancel(),
    ];

    for (final command in commands) {
      final message = ClientCommand(requestId: 'request', command: command);
      expect(
        ClientCommand.bincodeDeserialize(message.bincodeSerialize()),
        message,
      );
    }
    expect(commands[1].toString(), contains('credential: [REDACTED]'));
    expect(commands[1].toString(), isNot(contains('runtime-token')));
    final correction = commands.whereType<CommandCorrectMemory>().single;
    expect(correction.toString(), contains('text: [REDACTED]'));
    expect(correction.toString(), contains('value: [REDACTED]'));
    expect(correction.toString(), isNot(contains('I moved to Beta')));
  });

  test('generated audio contract keeps bytes separate', () {
    final chunk = AudioChunk(
      requestId: 'voice',
      sequence: Uint64.fromBigInt(BigInt.one),
      sampleRateHz: 16000,
      channels: 1,
      encoding: AudioEncoding.pcmS16Le,
      endOfStream: false,
    );

    expect(AudioChunk.bincodeDeserialize(chunk.bincodeSerialize()), chunk);
    expect(Uint8List.fromList([1, 2]), hasLength(2));
  });

  test('approval decision acknowledgement round trips', () {
    const event = NativeEventApprovalDecisionAcknowledged(
      value: ApprovalDecisionAcknowledgement(
        requestId: 'approval-1',
        proposalId: 'proposal-1',
        decision: ApprovalDecision.approveOnce,
        accepted: true,
        executionPending: true,
      ),
    );

    expect(NativeEvent.bincodeDeserialize(event.bincodeSerialize()), event);
  });

  test('memory export and local item events round trip', () {
    const exported = NativeEventMemoryExported(
      value: MemoryExported(
        requestId: 'export-1',
        exportFormat: 1,
        databaseSchemaVersion: 8,
        highWaterMark: 4,
        nextAfterCommit: 4,
        nextAfterEventIndex: 1,
        complete: true,
        commits: [
          MemoryExportCommit(
            sequence: 4,
            recordedAtMs: 12,
            eventCount: 2,
            firstEventIndex: 0,
            recordsJson: ['{"kind":"source"}', '{"kind":"evidence"}'],
          ),
        ],
      ),
    );
    const items = NativeEventMemoryItems(
      value: MemoryItems(
        requestId: 'items-1',
        items: [
          MemoryItem(
            kind: 'profile',
            id: 'profile-1',
            title: 'employer',
            body: 'Acme',
            recordedAtMs: 12,
            evidenceIds: [],
          ),
        ],
      ),
    );

    expect(
      NativeEvent.bincodeDeserialize(exported.bincodeSerialize()),
      exported,
    );
    expect(NativeEvent.bincodeDeserialize(items.bincodeSerialize()), items);
    expect(exported.toString(), contains('[REDACTED]'));
    expect(exported.toString(), isNot(contains('{"kind":"source"}')));
    expect(items.toString(), contains('[REDACTED]'));
    expect(items.toString(), isNot(contains('Acme')));
  });

  test('transcription stop acknowledgement round trips independently', () {
    const event = NativeEventTranscriptionStopAcknowledged(
      value: TranscriptionStopAcknowledgement(
        requestId: 'stop-voice-1',
        audioStreamId: 'voice-1',
        accepted: true,
      ),
    );

    expect(NativeEvent.bincodeDeserialize(event.bincodeSerialize()), event);
  });

  test('unavailable hub does not claim native capability', () async {
    const hub = UnavailableNativeHub('web uses the Worker');

    expect(hub.available, isFalse);
    expect(await hub.events.isEmpty, isTrue);
    expect(
      () => hub.search(requestId: 'request', query: 'memory'),
      throwsA(isA<NativeHubUnavailable>()),
    );
  });

  test('unavailable hub refuses every command and names the reason', () {
    const hub = UnavailableNativeHub('web uses the Worker');

    for (final call in _everyCommand(hub)) {
      expect(
        call,
        throwsA(
          isA<NativeHubUnavailable>().having(
            (error) => error.message,
            'message',
            'web uses the Worker',
          ),
        ),
      );
    }
    expect(
      const NativeHubUnavailable('nope').toString(),
      'NativeHubUnavailable: nope',
    );
  });

  test('unavailable hub tolerates lifecycle calls', () async {
    const hub = UnavailableNativeHub('web uses the Worker');

    await hub.initialize();
    hub.dispose();
    hub.dispose();
  });

  test('rinf hub refuses every command before initialize', () {
    final hub = RinfNativeHub();

    expect(hub.available, isTrue);
    for (final call in _everyCommand(hub)) {
      expect(
        call,
        throwsA(
          isA<NativeHubUnavailable>().having(
            (error) => error.message,
            'message',
            'Native hub is not initialized.',
          ),
        ),
      );
    }
  });

  test('rinf hub disposing before initialize is a no-op', () {
    final hub = RinfNativeHub();

    hub.dispose();
    expect(() => hub.cancel('request'), throwsA(isA<NativeHubUnavailable>()));
  });
}

/// Every mutating entry point on the hub, so a hub that cannot serve them is
/// forced to say so uniformly instead of dropping commands on the floor.
List<void Function()> _everyCommand(NativeHub hub) => [
  () => hub.configureMemory(
    requestId: 'request',
    databasePath: '/tmp/omi.db',
    tenantId: 'tenant',
    personId: 'person',
  ),
  () => hub.capture(
    requestId: 'request',
    ingestionKey: 'key',
    source: CaptureSource.screen,
    occurredAtMs: 1,
    recordedAtMs: 2,
  ),
  () => hub.search(requestId: 'request', query: 'memory'),
  () => hub.exportMemory(requestId: 'request'),
  () => hub.listMemoryItems(requestId: 'request'),
  () => hub.correctMemory(
    requestId: 'request',
    claimId: 'claim',
    text: 'text',
    value: 'value',
    occurredAtMs: 1,
    recordedAtMs: 2,
  ),
  () => hub.deleteMemorySource(
    requestId: 'request',
    sourceId: 'source',
    deletedAtMs: 3,
  ),
  () => hub.scanOnboarding(
    requestId: 'request',
    roots: const ['/tmp'],
    includeAppleNotes: false,
    includeAppleMail: false,
    recordedAtMs: 4,
  ),
  () => hub.sendMessage(requestId: 'request', text: 'hello'),
  () => hub.configureAssistant(
    requestId: 'request',
    provider: AssistantProvider.worker,
    model: 'managed-chat',
    credential: 'token',
  ),
  () => hub.configureTrustedAssistant(
    requestId: 'request',
    managedWorkerOrigin: 'https://assistant.example.test',
  ),
  () => hub.clearAssistant('request'),
  () => hub.decideApproval(
    requestId: 'request',
    proposalId: 'proposal',
    decision: ApprovalDecision.approveOnce,
  ),
  () => hub.startTranscription(
    requestId: 'request',
    audioStreamId: 'voice-1',
    deviceId: 'device-1',
    auth: const TranscriptionAuthLocal(),
    language: 'en',
    sampleRateHz: 16000,
    channels: 1,
    encoding: AudioEncoding.pcmS16Le,
  ),
  () => hub.stopTranscription(requestId: 'request', audioStreamId: 'voice-1'),
  () => hub.startLiveVoice(
    requestId: 'request',
    liveStreamId: 'live-1',
    ephemeralToken: 'token',
    model: 'live',
  ),
  () => hub.stopLiveVoice(requestId: 'request', liveStreamId: 'live-1'),
  () => hub.startMeeting(requestId: 'request', title: 'standup'),
  () => hub.stopMeeting('request'),
  () => hub.jotMeetingNote(requestId: 'request', text: 'note'),
  () => hub.provideMeetingAuth(
    requestId: 'request',
    auth: const TranscriptionAuthLocal(),
  ),
  () => hub.setSystemAudioCaptureMode(
    requestId: 'request',
    mode: SystemAudioCaptureMode.onlyDuringMeetings,
  ),
  () => hub.cancel('request'),
  () => hub.sendAudio(
    requestId: 'request',
    sequence: 0,
    sampleRateHz: 16000,
    channels: 1,
    encoding: AudioEncoding.pcmS16Le,
    endOfStream: false,
    bytes: Uint8List.fromList([1, 2]),
  ),
];
