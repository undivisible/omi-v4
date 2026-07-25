// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// What Omi knows about the screen at the instant the policy is asked whether
/// to capture. Deliberately tiny: the frontmost app, its bundle id, and the
/// window title. Nothing here is stored unless a frame is stored.
@immutable
class RewindWindowContext {
  const RewindWindowContext({this.bundleId, this.appName, this.windowTitle});

  static RewindWindowContext deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindWindowContext(
      bundleId: TraitHelpers.deserializeOptionStr(deserializer),
      appName: TraitHelpers.deserializeOptionStr(deserializer),
      windowTitle: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RewindWindowContext bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RewindWindowContext.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String? bundleId;
  final String? appName;
  final String? windowTitle;

  RewindWindowContext copyWith({
    String? Function()? bundleId,
    String? Function()? appName,
    String? Function()? windowTitle,
  }) {
    return RewindWindowContext(
      bundleId: bundleId == null ? this.bundleId : bundleId(),
      appName: appName == null ? this.appName : appName(),
      windowTitle: windowTitle == null ? this.windowTitle : windowTitle(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    TraitHelpers.serializeOptionStr(bundleId, serializer);
    TraitHelpers.serializeOptionStr(appName, serializer);
    TraitHelpers.serializeOptionStr(windowTitle, serializer);
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

    return other is RewindWindowContext &&
        bundleId == other.bundleId &&
        appName == other.appName &&
        windowTitle == other.windowTitle;
  }

  @override
  int get hashCode => Object.hash(bundleId, appName, windowTitle);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'bundleId: $bundleId, '
          'appName: $appName, '
          'windowTitle: $windowTitle'
          ')';
      return true;
    }());

    return fullString ?? 'RewindWindowContext';
  }
}
