// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class TranscriptLocator {
  const TranscriptLocator({
    required this.deviceId,
    required this.provider,
    required this.streamId,
    required this.segmentId,
    required this.startMs,
    required this.endMs,
  });

  static TranscriptLocator deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TranscriptLocator(
      deviceId: deserializer.deserializeString(),
      provider: deserializer.deserializeString(),
      streamId: deserializer.deserializeString(),
      segmentId: deserializer.deserializeString(),
      startMs: deserializer.deserializeInt64(),
      endMs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static TranscriptLocator bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TranscriptLocator.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String deviceId;
  final String provider;
  final String streamId;
  final String segmentId;
  final int startMs;
  final int endMs;

  TranscriptLocator copyWith({
    String? deviceId,
    String? provider,
    String? streamId,
    String? segmentId,
    int? startMs,
    int? endMs,
  }) {
    return TranscriptLocator(
      deviceId: deviceId ?? this.deviceId,
      provider: provider ?? this.provider,
      streamId: streamId ?? this.streamId,
      segmentId: segmentId ?? this.segmentId,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(deviceId);
    serializer.serializeString(provider);
    serializer.serializeString(streamId);
    serializer.serializeString(segmentId);
    serializer.serializeInt64(startMs);
    serializer.serializeInt64(endMs);
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

    return other is TranscriptLocator &&
        deviceId == other.deviceId &&
        provider == other.provider &&
        streamId == other.streamId &&
        segmentId == other.segmentId &&
        startMs == other.startMs &&
        endMs == other.endMs;
  }

  @override
  int get hashCode =>
      Object.hash(deviceId, provider, streamId, segmentId, startMs, endMs);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'deviceId: $deviceId, '
          'provider: $provider, '
          'streamId: $streamId, '
          'segmentId: $segmentId, '
          'startMs: $startMs, '
          'endMs: $endMs'
          ')';
      return true;
    }());

    return fullString ?? 'TranscriptLocator';
  }
}
