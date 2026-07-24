// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class ToolProgress {
  const ToolProgress({
    required this.requestId,
    required this.tool,
    required this.status,
    this.detail,
  });

  static ToolProgress deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ToolProgress(
      requestId: deserializer.deserializeString(),
      tool: deserializer.deserializeString(),
      status: ToolStatusExtension.deserialize(deserializer),
      detail: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ToolProgress bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ToolProgress.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final String tool;
  final ToolStatus status;
  final String? detail;

  ToolProgress copyWith({
    String? requestId,
    String? tool,
    ToolStatus? status,
    String? Function()? detail,
  }) {
    return ToolProgress(
      requestId: requestId ?? this.requestId,
      tool: tool ?? this.tool,
      status: status ?? this.status,
      detail: detail == null ? this.detail : detail(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    serializer.serializeString(tool);
    status.serialize(serializer);
    TraitHelpers.serializeOptionStr(detail, serializer);
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

    return other is ToolProgress &&
        requestId == other.requestId &&
        tool == other.tool &&
        status == other.status &&
        detail == other.detail;
  }

  @override
  int get hashCode => Object.hash(requestId, tool, status, detail);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'tool: $tool, '
          'status: $status, '
          'detail: $detail'
          ')';
      return true;
    }());

    return fullString ?? 'ToolProgress';
  }
}
