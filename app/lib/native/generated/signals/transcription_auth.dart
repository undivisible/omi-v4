// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

abstract class TranscriptionAuth {
  const TranscriptionAuth();

  void serialize(BinarySerializer serializer);

  static TranscriptionAuth deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return TranscriptionAuthManaged.load(deserializer);
      case 1:
        return TranscriptionAuthByok.load(deserializer);
      case 2:
        return TranscriptionAuthLocal.load(deserializer);
      default:
        throw Exception(
          'Unknown variant index for TranscriptionAuth: ' + index.toString(),
        );
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static TranscriptionAuth bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TranscriptionAuth.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

@immutable
class TranscriptionAuthManaged extends TranscriptionAuth {
  const TranscriptionAuthManaged({
    required this.endpoint,
    required this.firebaseToken,
  }) : super();

  static TranscriptionAuthManaged load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TranscriptionAuthManaged(
      endpoint: deserializer.deserializeString(),
      firebaseToken: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String endpoint;
  final String firebaseToken;

  TranscriptionAuthManaged copyWith({String? endpoint, String? firebaseToken}) {
    return TranscriptionAuthManaged(
      endpoint: endpoint ?? this.endpoint,
      firebaseToken: firebaseToken ?? this.firebaseToken,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeString(endpoint);
    serializer.serializeString(firebaseToken);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is TranscriptionAuthManaged &&
        endpoint == other.endpoint &&
        firebaseToken == other.firebaseToken;
  }

  @override
  int get hashCode => Object.hash(endpoint, firebaseToken);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'endpoint: $endpoint, '
          'firebaseToken: [REDACTED]'
          ')';
      return true;
    }());

    return fullString ?? 'TranscriptionAuthManaged';
  }
}

@immutable
class TranscriptionAuthByok extends TranscriptionAuth {
  const TranscriptionAuthByok({required this.endpoint, required this.apiKey})
    : super();

  static TranscriptionAuthByok load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TranscriptionAuthByok(
      endpoint: deserializer.deserializeString(),
      apiKey: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String endpoint;
  final String apiKey;

  TranscriptionAuthByok copyWith({String? endpoint, String? apiKey}) {
    return TranscriptionAuthByok(
      endpoint: endpoint ?? this.endpoint,
      apiKey: apiKey ?? this.apiKey,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(endpoint);
    serializer.serializeString(apiKey);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is TranscriptionAuthByok &&
        endpoint == other.endpoint &&
        apiKey == other.apiKey;
  }

  @override
  int get hashCode => Object.hash(endpoint, apiKey);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'endpoint: $endpoint, '
          'apiKey: [REDACTED]'
          ')';
      return true;
    }());

    return fullString ?? 'TranscriptionAuthByok';
  }
}

@immutable
class TranscriptionAuthLocal extends TranscriptionAuth {
  const TranscriptionAuthLocal() : super();

  static TranscriptionAuthLocal load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TranscriptionAuthLocal();
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is TranscriptionAuthLocal;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          ')';
      return true;
    }());

    return fullString ?? 'TranscriptionAuthLocal';
  }
}
