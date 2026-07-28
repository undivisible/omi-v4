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
    required this.display,
    this.appName,
    this.bundleId,
    this.windowTitle,
    this.ocrText,
    this.visualCaption,
  });

  static RewindFrameRecord deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RewindFrameRecord(
      capturedAtMs: deserializer.deserializeInt64(),
      relativePath: deserializer.deserializeString(),
      absolutePath: deserializer.deserializeString(),
      bytes: deserializer.deserializeUint64(),
      hash: deserializer.deserializeString(),
      display: RewindDisplay.deserialize(deserializer),
      appName: TraitHelpers.deserializeOptionStr(deserializer),
      bundleId: TraitHelpers.deserializeOptionStr(deserializer),
      windowTitle: TraitHelpers.deserializeOptionStr(deserializer),
      ocrText: TraitHelpers.deserializeOptionStr(deserializer),
      visualCaption: TraitHelpers.deserializeOptionRewindVisualCaption(
        deserializer,
      ),
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
  final RewindDisplay display;
  final String? appName;
  final String? bundleId;
  final String? windowTitle;
  final String? ocrText;
  final RewindVisualCaption? visualCaption;

  RewindFrameRecord copyWith({
    int? capturedAtMs,
    String? relativePath,
    String? absolutePath,
    Uint64? bytes,
    String? hash,
    RewindDisplay? display,
    String? Function()? appName,
    String? Function()? bundleId,
    String? Function()? windowTitle,
    String? Function()? ocrText,
    RewindVisualCaption? Function()? visualCaption,
  }) {
    return RewindFrameRecord(
      capturedAtMs: capturedAtMs ?? this.capturedAtMs,
      relativePath: relativePath ?? this.relativePath,
      absolutePath: absolutePath ?? this.absolutePath,
      bytes: bytes ?? this.bytes,
      hash: hash ?? this.hash,
      display: display ?? this.display,
      appName: appName == null ? this.appName : appName(),
      bundleId: bundleId == null ? this.bundleId : bundleId(),
      windowTitle: windowTitle == null ? this.windowTitle : windowTitle(),
      ocrText: ocrText == null ? this.ocrText : ocrText(),
      visualCaption: visualCaption == null
          ? this.visualCaption
          : visualCaption(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeInt64(capturedAtMs);
    serializer.serializeString(relativePath);
    serializer.serializeString(absolutePath);
    serializer.serializeUint64(bytes);
    serializer.serializeString(hash);
    display.serialize(serializer);
    TraitHelpers.serializeOptionStr(appName, serializer);
    TraitHelpers.serializeOptionStr(bundleId, serializer);
    TraitHelpers.serializeOptionStr(windowTitle, serializer);
    TraitHelpers.serializeOptionStr(ocrText, serializer);
    TraitHelpers.serializeOptionRewindVisualCaption(visualCaption, serializer);
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
        display == other.display &&
        appName == other.appName &&
        bundleId == other.bundleId &&
        windowTitle == other.windowTitle &&
        ocrText == other.ocrText &&
        visualCaption == other.visualCaption;
  }

  @override
  int get hashCode => Object.hash(
    capturedAtMs,
    relativePath,
    absolutePath,
    bytes,
    hash,
    display,
    appName,
    bundleId,
    windowTitle,
    ocrText,
    visualCaption,
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
          'display: $display, '
          'appName: $appName, '
          'bundleId: $bundleId, '
          'windowTitle: $windowTitle, '
          'ocrText: $ocrText, '
          'visualCaption: $visualCaption'
          ')';
      return true;
    }());

    return fullString ?? 'RewindFrameRecord';
  }
}
