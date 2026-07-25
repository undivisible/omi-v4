// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// What the voice-activity gate kept off the metered transcription socket for
/// one audio stream, so the saving can be seen rather than assumed. It is a
/// local signal to the client and goes nowhere else.
///
/// `gateable` is `false` for an encoding whose loudness cannot be read without
/// decoding it — Opus, today — and such a stream is passed through in full
/// rather than gated on a guess. Reading `suppressed_bytes` as a saving is only
/// meaningful when `enabled` and `gateable` are both true.
@immutable
class AudioGateStats {
  const AudioGateStats({
    required this.audioStreamId,
    required this.enabled,
    required this.gateable,
    required this.forwardedBytes,
    required this.suppressedBytes,
    required this.forwardedMs,
    required this.suppressedMs,
  });

  static AudioGateStats deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = AudioGateStats(
      audioStreamId: deserializer.deserializeString(),
      enabled: deserializer.deserializeBool(),
      gateable: deserializer.deserializeBool(),
      forwardedBytes: deserializer.deserializeUint64(),
      suppressedBytes: deserializer.deserializeUint64(),
      forwardedMs: deserializer.deserializeUint64(),
      suppressedMs: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static AudioGateStats bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = AudioGateStats.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String audioStreamId;
  final bool enabled;
  final bool gateable;
  final Uint64 forwardedBytes;
  final Uint64 suppressedBytes;
  final Uint64 forwardedMs;
  final Uint64 suppressedMs;

  AudioGateStats copyWith({
    String? audioStreamId,
    bool? enabled,
    bool? gateable,
    Uint64? forwardedBytes,
    Uint64? suppressedBytes,
    Uint64? forwardedMs,
    Uint64? suppressedMs,
  }) {
    return AudioGateStats(
      audioStreamId: audioStreamId ?? this.audioStreamId,
      enabled: enabled ?? this.enabled,
      gateable: gateable ?? this.gateable,
      forwardedBytes: forwardedBytes ?? this.forwardedBytes,
      suppressedBytes: suppressedBytes ?? this.suppressedBytes,
      forwardedMs: forwardedMs ?? this.forwardedMs,
      suppressedMs: suppressedMs ?? this.suppressedMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(audioStreamId);
    serializer.serializeBool(enabled);
    serializer.serializeBool(gateable);
    serializer.serializeUint64(forwardedBytes);
    serializer.serializeUint64(suppressedBytes);
    serializer.serializeUint64(forwardedMs);
    serializer.serializeUint64(suppressedMs);
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

    return other is AudioGateStats &&
        audioStreamId == other.audioStreamId &&
        enabled == other.enabled &&
        gateable == other.gateable &&
        forwardedBytes == other.forwardedBytes &&
        suppressedBytes == other.suppressedBytes &&
        forwardedMs == other.forwardedMs &&
        suppressedMs == other.suppressedMs;
  }

  @override
  int get hashCode => Object.hash(
    audioStreamId,
    enabled,
    gateable,
    forwardedBytes,
    suppressedBytes,
    forwardedMs,
    suppressedMs,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'audioStreamId: $audioStreamId, '
          'enabled: $enabled, '
          'gateable: $gateable, '
          'forwardedBytes: $forwardedBytes, '
          'suppressedBytes: $suppressedBytes, '
          'forwardedMs: $forwardedMs, '
          'suppressedMs: $suppressedMs'
          ')';
      return true;
    }());

    return fullString ?? 'AudioGateStats';
  }
}
