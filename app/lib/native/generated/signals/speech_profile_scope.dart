// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Which account's voiceprints a speech-profile command addresses, and where
/// they live.
///
/// The client resolves `directory` from the same `~/.omi` convention every
/// other local store uses; the hub never invents a location for someone's
/// voiceprints. `uid` scopes every row, so a shared machine cannot show one
/// account the other's people.
@immutable
class SpeechProfileScope {
  const SpeechProfileScope({required this.directory, required this.uid});

  static SpeechProfileScope deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = SpeechProfileScope(
      directory: deserializer.deserializeString(),
      uid: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static SpeechProfileScope bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SpeechProfileScope.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String directory;
  final String uid;

  SpeechProfileScope copyWith({String? directory, String? uid}) {
    return SpeechProfileScope(
      directory: directory ?? this.directory,
      uid: uid ?? this.uid,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(directory);
    serializer.serializeString(uid);
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

    return other is SpeechProfileScope &&
        directory == other.directory &&
        uid == other.uid;
  }

  @override
  int get hashCode => Object.hash(directory, uid);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'directory: $directory, '
          'uid: $uid'
          ')';
      return true;
    }());

    return fullString ?? 'SpeechProfileScope';
  }
}
