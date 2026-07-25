// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The answer to a [`Command::AppendCaptureAudio`]. Sent once the bytes have
/// been handed to the operating system, or once the write has failed — either
/// way the client may stop holding the frame. `error` never means the frame
/// should be re-sent: the log has already moved past it, and a duplicate
/// append would put the same audio into the segment twice.
@immutable
class CaptureAudioAppended {
  const CaptureAudioAppended({required this.requestId, this.error});

  static CaptureAudioAppended deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CaptureAudioAppended(
      requestId: deserializer.deserializeString(),
      error: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static CaptureAudioAppended bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CaptureAudioAppended.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String? error;

  CaptureAudioAppended copyWith({
    String? requestId,
    String? Function()? error,
  }) {
    return CaptureAudioAppended(
      requestId: requestId ?? this.requestId,
      error: error == null ? this.error : error(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    TraitHelpers.serializeOptionStr(error, serializer);
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

    return other is CaptureAudioAppended &&
        requestId == other.requestId &&
        error == other.error;
  }

  @override
  int get hashCode => Object.hash(requestId, error);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'error: $error'
          ')';
      return true;
    }());

    return fullString ?? 'CaptureAudioAppended';
  }
}
