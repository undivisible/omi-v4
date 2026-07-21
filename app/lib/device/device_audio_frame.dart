import 'dart:typed_data';

class DeviceAudioFrame {
  DeviceAudioFrame({
    required this.packetId,
    required this.packetIndex,
    required List<int> payload,
  }) : payload = Uint8List.fromList(payload);

  static const int headerSize = 3;

  final int packetId;
  final int packetIndex;
  final Uint8List payload;

  static DeviceAudioFrame? decode(List<int> packet) {
    if (packet.length <= headerSize) return null;
    return DeviceAudioFrame(
      packetId: packet[0] | (packet[1] << 8),
      packetIndex: packet[2],
      payload: packet.sublist(headerSize),
    );
  }
}
