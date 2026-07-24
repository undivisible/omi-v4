// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class TranscriptGap {
  const TranscriptGap({
    required this.requestId,
    required this.audioStreamId,
    required this.sttEpoch,
    required this.startMs,
    required this.endMs,
    required this.reason,
  });

  static TranscriptGap deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TranscriptGap(
      requestId: deserializer.deserializeString(),
      audioStreamId: deserializer.deserializeString(),
      sttEpoch: deserializer.deserializeUint32(),
      startMs: deserializer.deserializeInt64(),
      endMs: deserializer.deserializeInt64(),
      reason: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static TranscriptGap bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TranscriptGap.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String audioStreamId;
  final int sttEpoch;
  final int startMs;
  final int endMs;
  final String reason;

  TranscriptGap copyWith({
    String? requestId,
    String? audioStreamId,
    int? sttEpoch,
    int? startMs,
    int? endMs,
    String? reason,
  }) {
    return TranscriptGap(
      requestId: requestId ?? this.requestId,
      audioStreamId: audioStreamId ?? this.audioStreamId,
      sttEpoch: sttEpoch ?? this.sttEpoch,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      reason: reason ?? this.reason,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeString(audioStreamId);
    serializer.serializeUint32(sttEpoch);
    serializer.serializeInt64(startMs);
    serializer.serializeInt64(endMs);
    serializer.serializeString(reason);
    serializer.decreaseContainerDepth();
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is TranscriptGap &&
        requestId == other.requestId &&
        audioStreamId == other.audioStreamId &&
        sttEpoch == other.sttEpoch &&
        startMs == other.startMs &&
        endMs == other.endMs &&
        reason == other.reason;
  }

  @override
  int get hashCode =>
      Object.hash(requestId, audioStreamId, sttEpoch, startMs, endMs, reason);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'audioStreamId: $audioStreamId, '
          'sttEpoch: $sttEpoch, '
          'startMs: $startMs, '
          'endMs: $endMs, '
          'reason: $reason'
          ')';
      return true;
    }());

    return fullString ?? 'TranscriptGap';
  }
}
