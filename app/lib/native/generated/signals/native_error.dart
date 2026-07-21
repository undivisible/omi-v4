// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class NativeError {
  const NativeError({
    this.requestId,
    required this.code,
    required this.message,
    required this.retryable,
  });

  static NativeError deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = NativeError(
      requestId: TraitHelpers.deserializeOptionStr(deserializer),
      code: deserializer.deserializeString(),
      message: deserializer.deserializeString(),
      retryable: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static NativeError bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = NativeError.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String? requestId;
  final String code;
  final String message;
  final bool retryable;

  NativeError copyWith({
    String? Function()? requestId,
    String? code,
    String? message,
    bool? retryable,
  }) {
    return NativeError(
      requestId: requestId == null ? this.requestId : requestId(),
      code: code ?? this.code,
      message: message ?? this.message,
      retryable: retryable ?? this.retryable,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    TraitHelpers.serializeOptionStr(requestId, serializer);
    serializer.serializeString(code);
    serializer.serializeString(message);
    serializer.serializeBool(retryable);
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

    return other is NativeError &&
        requestId == other.requestId &&
        code == other.code &&
        message == other.message &&
        retryable == other.retryable;
  }

  @override
  int get hashCode => Object.hash(requestId, code, message, retryable);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'code: $code, '
          'message: $message, '
          'retryable: $retryable'
          ')';
      return true;
    }());

    return fullString ?? 'NativeError';
  }
}
