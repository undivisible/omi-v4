import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:rinf/rinf.dart';

import 'generated/signals/signals.dart';

export 'generated/signals/signals.dart'
    show
        AudioEncoding,
        CaptureSource,
        NativeEvent,
        NativeEventError,
        NativeEventMemoryCaptured,
        NativeEventTranscriptDelta,
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
