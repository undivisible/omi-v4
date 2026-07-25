// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The answer to a [`Command::OpenCaptureWal`]. `directory` is the log the hub
/// settled on, so the client can show where audio is being kept; `error`
/// carries why there is no log at all, which degrades capture to "live only"
/// rather than stopping it.
@immutable
class CaptureWalOpened {
  const CaptureWalOpened({required this.requestId, this.directory, this.error});

  static CaptureWalOpened deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CaptureWalOpened(
      requestId: deserializer.deserializeString(),
      directory: TraitHelpers.deserializeOptionStr(deserializer),
      error: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static CaptureWalOpened bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CaptureWalOpened.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String? directory;
  final String? error;

  CaptureWalOpened copyWith({
    String? requestId,
    String? Function()? directory,
    String? Function()? error,
  }) {
    return CaptureWalOpened(
      requestId: requestId ?? this.requestId,
      directory: directory == null ? this.directory : directory(),
      error: error == null ? this.error : error(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    TraitHelpers.serializeOptionStr(directory, serializer);
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

    return other is CaptureWalOpened &&
        requestId == other.requestId &&
        directory == other.directory &&
        error == other.error;
  }

  @override
  int get hashCode => Object.hash(requestId, directory, error);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'directory: $directory, '
          'error: $error'
          ')';
      return true;
    }());

    return fullString ?? 'CaptureWalOpened';
  }
}
