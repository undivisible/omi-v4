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
      const CommandSearchMemory(query: 'this', limit: 12),
      const CommandCorrectMemory(
        claimId: 'claim-1',
        text: 'I moved to Beta',
        value: 'Beta',
        occurredAtMs: 43,
        recordedAtMs: 46,
      ),
      const CommandDeleteMemorySource(sourceId: 'source-1', deletedAtMs: 44),
      const CommandApproveAndExecuteComputerUse(proposalId: 'proposal-1'),
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
    expect(commands[6].toString(), contains('text: [REDACTED]'));
    expect(commands[6].toString(), contains('value: [REDACTED]'));
    expect(commands[6].toString(), isNot(contains('I moved to Beta')));
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

  test('approval execution acknowledgement round trips', () {
    const event = NativeEventApprovalExecutionAcknowledged(
      value: ApprovalExecutionAcknowledgement(
        requestId: 'approval-1',
        proposalId: 'proposal-1',
        accepted: true,
      ),
    );

    expect(NativeEvent.bincodeDeserialize(event.bincodeSerialize()), event);
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
}
