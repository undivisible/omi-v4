// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class AudioChunk {
  const AudioChunk({
    required this.requestId,
    required this.sequence,
    required this.sampleRateHz,
    required this.channels,
    required this.encoding,
    required this.endOfStream,
  });

  static AudioChunk deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = AudioChunk(
      requestId: deserializer.deserializeString(),
      sequence: deserializer.deserializeUint64(),
      sampleRateHz: deserializer.deserializeUint32(),
      channels: deserializer.deserializeUint8(),
      encoding: AudioEncodingExtension.deserialize(deserializer),
      endOfStream: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static AudioChunk bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = AudioChunk.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final Uint64 sequence;
  final int sampleRateHz;
  final int channels;
  final AudioEncoding encoding;
  final bool endOfStream;

  AudioChunk copyWith({
    String? requestId,
    Uint64? sequence,
    int? sampleRateHz,
    int? channels,
    AudioEncoding? encoding,
    bool? endOfStream,
  }) {
    return AudioChunk(
      requestId: requestId ?? this.requestId,
      sequence: sequence ?? this.sequence,
      sampleRateHz: sampleRateHz ?? this.sampleRateHz,
      channels: channels ?? this.channels,
      encoding: encoding ?? this.encoding,
      endOfStream: endOfStream ?? this.endOfStream,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeUint64(sequence);
    serializer.serializeUint32(sampleRateHz);
    serializer.serializeUint8(channels);
    encoding.serialize(serializer);
    serializer.serializeBool(endOfStream);
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

    return other is AudioChunk &&
        requestId == other.requestId &&
        sequence == other.sequence &&
        sampleRateHz == other.sampleRateHz &&
        channels == other.channels &&
        encoding == other.encoding &&
        endOfStream == other.endOfStream;
  }

  @override
  int get hashCode => Object.hash(
    requestId,
    sequence,
    sampleRateHz,
    channels,
    encoding,
    endOfStream,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'sequence: $sequence, '
          'sampleRateHz: $sampleRateHz, '
          'channels: $channels, '
          'encoding: $encoding, '
          'endOfStream: $endOfStream'
          ')';
      return true;
    }());

    return fullString ?? 'AudioChunk';
  }
}

extension AudioChunkDartSignalExt on AudioChunk {
  /// Sends the signal to Rust with separate binary data.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust(Uint8List binary) {
    final messageBytes = bincodeSerialize();
    sendDartSignal('rinf_send_dart_signal_audio_chunk', messageBytes, binary);
  }
}
