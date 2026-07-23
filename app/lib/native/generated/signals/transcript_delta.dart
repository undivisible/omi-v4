// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class TranscriptDelta {
  const TranscriptDelta({
    required this.requestId,
    required this.audioStreamId,
    required this.segmentId,
    required this.segmentSequence,
    required this.sttEpoch,
    required this.deviceId,
    required this.provider,
    required this.startMs,
    required this.endMs,
    required this.occurredAtMs,
    required this.text,
    required this.finalSegment,
    this.speaker,
    this.channelIndex,
    this.language,
  });

  static TranscriptDelta deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TranscriptDelta(
      requestId: deserializer.deserializeString(),
      audioStreamId: deserializer.deserializeString(),
      segmentId: deserializer.deserializeString(),
      segmentSequence: deserializer.deserializeUint64(),
      sttEpoch: deserializer.deserializeUint32(),
      deviceId: deserializer.deserializeString(),
      provider: deserializer.deserializeString(),
      startMs: deserializer.deserializeInt64(),
      endMs: deserializer.deserializeInt64(),
      occurredAtMs: deserializer.deserializeInt64(),
      text: deserializer.deserializeString(),
      finalSegment: deserializer.deserializeBool(),
      speaker: TraitHelpers.deserializeOptionU32(deserializer),
      channelIndex: TraitHelpers.deserializeOptionU32(deserializer),
      language: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static TranscriptDelta bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TranscriptDelta.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String audioStreamId;
  final String segmentId;
  final Uint64 segmentSequence;
  final int sttEpoch;
  final String deviceId;
  final String provider;
  final int startMs;
  final int endMs;
  final int occurredAtMs;
  final String text;
  final bool finalSegment;
  final int? speaker;
  final int? channelIndex;
  final String? language;

  TranscriptDelta copyWith({
    String? requestId,
    String? audioStreamId,
    String? segmentId,
    Uint64? segmentSequence,
    int? sttEpoch,
    String? deviceId,
    String? provider,
    int? startMs,
    int? endMs,
    int? occurredAtMs,
    String? text,
    bool? finalSegment,
    int? Function()? speaker,
    int? Function()? channelIndex,
    String? Function()? language,
  }) {
    return TranscriptDelta(
      requestId: requestId ?? this.requestId,
      audioStreamId: audioStreamId ?? this.audioStreamId,
      segmentId: segmentId ?? this.segmentId,
      segmentSequence: segmentSequence ?? this.segmentSequence,
      sttEpoch: sttEpoch ?? this.sttEpoch,
      deviceId: deviceId ?? this.deviceId,
      provider: provider ?? this.provider,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      occurredAtMs: occurredAtMs ?? this.occurredAtMs,
      text: text ?? this.text,
      finalSegment: finalSegment ?? this.finalSegment,
      speaker: speaker == null ? this.speaker : speaker(),
      channelIndex: channelIndex == null ? this.channelIndex : channelIndex(),
      language: language == null ? this.language : language(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeString(audioStreamId);
    serializer.serializeString(segmentId);
    serializer.serializeUint64(segmentSequence);
    serializer.serializeUint32(sttEpoch);
    serializer.serializeString(deviceId);
    serializer.serializeString(provider);
    serializer.serializeInt64(startMs);
    serializer.serializeInt64(endMs);
    serializer.serializeInt64(occurredAtMs);
    serializer.serializeString(text);
    serializer.serializeBool(finalSegment);
    TraitHelpers.serializeOptionU32(speaker, serializer);
    TraitHelpers.serializeOptionU32(channelIndex, serializer);
    TraitHelpers.serializeOptionStr(language, serializer);
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

    return other is TranscriptDelta &&
        requestId == other.requestId &&
        audioStreamId == other.audioStreamId &&
        segmentId == other.segmentId &&
        segmentSequence == other.segmentSequence &&
        sttEpoch == other.sttEpoch &&
        deviceId == other.deviceId &&
        provider == other.provider &&
        startMs == other.startMs &&
        endMs == other.endMs &&
        occurredAtMs == other.occurredAtMs &&
        text == other.text &&
        finalSegment == other.finalSegment &&
        speaker == other.speaker &&
        channelIndex == other.channelIndex &&
        language == other.language;
  }

  @override
  int get hashCode => Object.hash(
    requestId,
    audioStreamId,
    segmentId,
    segmentSequence,
    sttEpoch,
    deviceId,
    provider,
    startMs,
    endMs,
    occurredAtMs,
    text,
    finalSegment,
    speaker,
    channelIndex,
    language,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'audioStreamId: $audioStreamId, '
          'segmentId: $segmentId, '
          'segmentSequence: $segmentSequence, '
          'sttEpoch: $sttEpoch, '
          'deviceId: $deviceId, '
          'provider: $provider, '
          'startMs: $startMs, '
          'endMs: $endMs, '
          'occurredAtMs: $occurredAtMs, '
          'text: [REDACTED], '
          'finalSegment: $finalSegment, '
          'speaker: $speaker, '
          'channelIndex: $channelIndex, '
          'language: $language'
          ')';
      return true;
    }());

    return fullString ?? 'TranscriptDelta';
  }
}
