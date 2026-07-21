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
      const CommandCaptureEvent(
        ingestionKey: 'stable-capture',
        source: CaptureSource.screen,
        occurredAtMs: 42,
        text: 'remember this',
      ),
      const CommandSearchMemory(query: 'this', limit: 12),
      const CommandCancel(),
    ];

    for (final command in commands) {
      final message = ClientCommand(requestId: 'request', command: command);
      expect(
        ClientCommand.bincodeDeserialize(message.bincodeSerialize()),
        message,
      );
    }
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
