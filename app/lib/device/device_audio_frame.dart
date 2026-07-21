import 'dart:async';
import 'dart:typed_data';

enum DeviceAudioFrameError { discontinuity, tooLarge }

class DeviceAudioFrame {
  DeviceAudioFrame({
    required this.packetId,
    required this.packetIndex,
    required List<int> payload,
    int? firstPacketId,
    this.complete = true,
    this.error,
  }) : firstPacketId = firstPacketId ?? packetId,
       payload = Uint8List.fromList(payload);

  static const int headerSize = 3;

  final int packetId;
  final int firstPacketId;
  final int packetIndex;
  final Uint8List payload;
  final bool complete;
  final DeviceAudioFrameError? error;

  static DeviceAudioFrame? decode(List<int> packet) {
    if (packet.length <= headerSize) return null;
    return DeviceAudioFrame(
      packetId: packet[0] | (packet[1] << 8),
      packetIndex: packet[2],
      payload: packet.sublist(headerSize),
    );
  }
}

Stream<DeviceAudioFrame> decodeDeviceAudioFrames(Stream<List<int>> packets) =>
    Stream<DeviceAudioFrame>.eventTransformed(
      packets,
      (sink) => _DeviceAudioReassembler(sink),
    );

class _DeviceAudioReassembler implements EventSink<List<int>> {
  _DeviceAudioReassembler(this.sink);

  final EventSink<DeviceAudioFrame> sink;
  final payload = BytesBuilder(copy: false);
  static const maxPacketBytes = 256 * 1024;
  int? lastPacketId;
  int? lastPacketIndex;
  int? firstPacketId;
  var active = false;

  @override
  void add(List<int> packet) {
    final frame = DeviceAudioFrame.decode(packet);
    if (frame == null) return;
    if (frame.packetIndex == 0) {
      final previousPacketId = lastPacketId;
      final previousPacketIndex = lastPacketIndex;
      if (active && previousPacketId != null && previousPacketIndex != null) {
        if (frame.packetId != ((previousPacketId + 1) & 0xffff)) {
          payload.takeBytes();
          sink.add(
            DeviceAudioFrame(
              packetId: frame.packetId,
              packetIndex: frame.packetIndex,
              firstPacketId: previousPacketId,
              payload: const [],
              complete: false,
              error: DeviceAudioFrameError.discontinuity,
            ),
          );
        } else {
          sink.add(
            DeviceAudioFrame(
              packetId: previousPacketId,
              packetIndex: 0,
              firstPacketId: firstPacketId,
              payload: payload.takeBytes(),
            ),
          );
        }
      }
      if (frame.payload.length > maxPacketBytes) {
        sink.add(
          DeviceAudioFrame(
            packetId: frame.packetId,
            packetIndex: frame.packetIndex,
            firstPacketId: previousPacketId,
            payload: const [],
            complete: false,
            error: DeviceAudioFrameError.tooLarge,
          ),
        );
        active = false;
      } else {
        payload.add(frame.payload);
        active = true;
      }
      firstPacketId = frame.packetId;
    } else {
      final previousPacketId = lastPacketId;
      final previousPacketIndex = lastPacketIndex;
      final contiguous =
          active &&
          previousPacketId != null &&
          previousPacketIndex != null &&
          previousPacketIndex < 0xff &&
          frame.packetId == ((previousPacketId + 1) & 0xffff) &&
          frame.packetIndex == previousPacketIndex + 1 &&
          payload.length + frame.payload.length <= maxPacketBytes;
      if (!contiguous) {
        final discontinuity =
            active && previousPacketId != null && previousPacketIndex != null;
        payload.takeBytes();
        active = false;
        sink.add(
          DeviceAudioFrame(
            packetId: frame.packetId,
            packetIndex: frame.packetIndex,
            firstPacketId: discontinuity ? previousPacketId : null,
            payload: const [],
            complete: false,
            error: discontinuity ? DeviceAudioFrameError.discontinuity : null,
          ),
        );
      } else {
        payload.add(frame.payload);
      }
    }
    lastPacketId = frame.packetId;
    lastPacketIndex = frame.packetIndex;
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      sink.addError(error, stackTrace);

  @override
  void close() {
    final previousPacketId = lastPacketId;
    final previousPacketIndex = lastPacketIndex;
    if (active && previousPacketId != null && previousPacketIndex != null) {
      sink.add(
        DeviceAudioFrame(
          packetId: previousPacketId,
          packetIndex: 0,
          firstPacketId: firstPacketId,
          payload: payload.takeBytes(),
        ),
      );
    }
    sink.close();
  }
}
