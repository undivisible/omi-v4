// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A voiceprint match against a live meeting's diarized voice.
///
/// `distance` and `runner_up` travel with it because "who is this?" and "how
/// sure are we?" are the same question to anyone reading a name on a
/// transcript, and the margin between the two is what the acceptance test
/// actually turned on.
@immutable
class SpeechProfileMatched {
  const SpeechProfileMatched({
    required this.profileId,
    this.displayName,
    required this.meetingId,
    required this.diarizedKey,
    required this.distance,
    this.runnerUp,
  });

  static SpeechProfileMatched deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = SpeechProfileMatched(
      profileId: deserializer.deserializeString(),
      displayName: TraitHelpers.deserializeOptionStr(deserializer),
      meetingId: deserializer.deserializeString(),
      diarizedKey: deserializer.deserializeInt64(),
      distance: deserializer.deserializeFloat32(),
      runnerUp: TraitHelpers.deserializeOptionF32(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static SpeechProfileMatched bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SpeechProfileMatched.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String profileId;
  final String? displayName;
  final String meetingId;
  final int diarizedKey;
  final double distance;
  final double? runnerUp;

  SpeechProfileMatched copyWith({
    String? profileId,
    String? Function()? displayName,
    String? meetingId,
    int? diarizedKey,
    double? distance,
    double? Function()? runnerUp,
  }) {
    return SpeechProfileMatched(
      profileId: profileId ?? this.profileId,
      displayName: displayName == null ? this.displayName : displayName(),
      meetingId: meetingId ?? this.meetingId,
      diarizedKey: diarizedKey ?? this.diarizedKey,
      distance: distance ?? this.distance,
      runnerUp: runnerUp == null ? this.runnerUp : runnerUp(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(profileId);
    TraitHelpers.serializeOptionStr(displayName, serializer);
    serializer.serializeString(meetingId);
    serializer.serializeInt64(diarizedKey);
    serializer.serializeFloat32(distance);
    TraitHelpers.serializeOptionF32(runnerUp, serializer);
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

    return other is SpeechProfileMatched &&
        profileId == other.profileId &&
        displayName == other.displayName &&
        meetingId == other.meetingId &&
        diarizedKey == other.diarizedKey &&
        distance == other.distance &&
        runnerUp == other.runnerUp;
  }

  @override
  int get hashCode => Object.hash(
    profileId,
    displayName,
    meetingId,
    diarizedKey,
    distance,
    runnerUp,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'profileId: $profileId, '
          'displayName: [REDACTED], '
          'meetingId: $meetingId, '
          'diarizedKey: $diarizedKey, '
          'distance: $distance, '
          'runnerUp: $runnerUp'
          ')';
      return true;
    }());

    return fullString ?? 'SpeechProfileMatched';
  }
}
