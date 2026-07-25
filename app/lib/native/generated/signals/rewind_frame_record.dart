// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One stored screenshot, as the timeline renders it.
@immutable
class RewindFrameRecord {
  const RewindFrameRecord({
    required this.capturedAtMs,
    required this.relativePath,
    required this.absolutePath,
    required this.bytes,
    required this.hash,
    this.appName,
    this.bundleId,
    this.windowTitle,
    this.ocrText,
  });

  static RewindFrameRecord deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindFrameRecord(
      capturedAtMs: deserializer.deserializeInt64(),
      relativePath: deserializer.deserializeString(),
      absolutePath: deserializer.deserializeString(),
      bytes: deserializer.deserializeUint64(),
      hash: deserializer.deserializeString(),
      appName: TraitHelpers.deserializeOptionStr(deserializer),
      bundleId: TraitHelpers.deserializeOptionStr(deserializer),
      windowTitle: TraitHelpers.deserializeOptionStr(deserializer),
      ocrText: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RewindFrameRecord bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RewindFrameRecord.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int capturedAtMs;
  final String relativePath;
  final String absolutePath;
  final Uint64 bytes;
  final String hash;
  final String? appName;
  final String? bundleId;
  final String? windowTitle;
  final String? ocrText;

  RewindFrameRecord copyWith({
    int? capturedAtMs,
    String? relativePath,
    String? absolutePath,
    Uint64? bytes,
    String? hash,
    String? Function()? appName,
    String? Function()? bundleId,
    String? Function()? windowTitle,
    String? Function()? ocrText,
  }) {
    return RewindFrameRecord(
      capturedAtMs: capturedAtMs ?? this.capturedAtMs,
      relativePath: relativePath ?? this.relativePath,
      absolutePath: absolutePath ?? this.absolutePath,
      bytes: bytes ?? this.bytes,
      hash: hash ?? this.hash,
      appName: appName == null ? this.appName : appName(),
      bundleId: bundleId == null ? this.bundleId : bundleId(),
      windowTitle: windowTitle == null ? this.windowTitle : windowTitle(),
      ocrText: ocrText == null ? this.ocrText : ocrText(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeInt64(capturedAtMs);
    serializer.serializeString(relativePath);
    serializer.serializeString(absolutePath);
    serializer.serializeUint64(bytes);
    serializer.serializeString(hash);
    TraitHelpers.serializeOptionStr(appName, serializer);
    TraitHelpers.serializeOptionStr(bundleId, serializer);
    TraitHelpers.serializeOptionStr(windowTitle, serializer);
    TraitHelpers.serializeOptionStr(ocrText, serializer);
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

    return other is RewindFrameRecord &&
        capturedAtMs == other.capturedAtMs &&
        relativePath == other.relativePath &&
        absolutePath == other.absolutePath &&
        bytes == other.bytes &&
        hash == other.hash &&
        appName == other.appName &&
        bundleId == other.bundleId &&
        windowTitle == other.windowTitle &&
        ocrText == other.ocrText;
  }

  @override
  int get hashCode => Object.hash(
    capturedAtMs,
    relativePath,
    absolutePath,
    bytes,
    hash,
    appName,
    bundleId,
    windowTitle,
    ocrText,
  );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'capturedAtMs: $capturedAtMs, '
          'relativePath: $relativePath, '
          'absolutePath: $absolutePath, '
          'bytes: $bytes, '
          'hash: $hash, '
          'appName: $appName, '
          'bundleId: $bundleId, '
          'windowTitle: $windowTitle, '
          'ocrText: $ocrText'
          ')';
      return true;
    }());

    return fullString ?? 'RewindFrameRecord';
  }
}
