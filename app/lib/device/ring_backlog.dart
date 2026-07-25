import 'dart:async';
import 'dart:typed_data';

abstract interface class RingStorageBle {
  Stream<List<int>> get storageNotifications;
  Future<void> writeStorage(Uint8List bytes);
}

abstract interface class DurableRingSink {
  Future<void> importRange(DurableRingRange range);
}

final class DurableRingRange {
  const DurableRingRange({
    required this.sourceId,
    required this.deviceId,
    required this.startedAtMs,
    required this.frames,
  });

  final String sourceId;
  final String deviceId;
  final int startedAtMs;
  final List<Uint8List> frames;
}

final class RingInfo {
  const RingInfo({
    required this.readSequence,
    required this.writeSequence,
    required this.packetSize,
  });

  final int readSequence;
  final int writeSequence;
  final int packetSize;
}

final class RingBacklogProtocol {
  static const recordBytes = 444;
  static const info = 0x10;
  static const read = 0x11;
  static const advance = 0x12;
  static const notifyInfo = 0x02;
  static const notifyData = 0x03;
  static const notifyDone = 0x04;
  static const notifyReadBegin = 0x05;

  static Uint8List readCommand(int start, int count) {
    if (start < 0 || count <= 0) throw RangeError('invalid ring range');
    return (ByteData(13)
          ..setUint8(0, read)
          ..setUint64(1, start, Endian.big)
          ..setUint32(9, count, Endian.big))
        .buffer
        .asUint8List();
  }

  static Uint8List advanceCommand(int next) {
    if (next < 0) throw RangeError.value(next, 'next');
    return (ByteData(9)
          ..setUint8(0, advance)
          ..setUint64(1, next, Endian.big))
        .buffer
        .asUint8List();
  }

  static RingInfo? parseInfo(List<int> bytes) {
    if (bytes.length < 31 || bytes.first != notifyInfo) return null;
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    return RingInfo(
      readSequence: data.getUint64(1, Endian.big),
      writeSequence: data.getUint64(9, Endian.big),
      packetSize: data.getUint16(29, Endian.big),
    );
  }

  static List<Uint8List> frames(Uint8List record) {
    if (record.length != recordBytes) throw FormatException('invalid record');
    final frames = <Uint8List>[];
    var offset = 4;
    while (offset < record.length - 1) {
      final length = record[offset++];
      if (length == 0) continue;
      if (offset + length >= record.length) {
        throw FormatException('truncated frame');
      }
      frames.add(Uint8List.sublistView(record, offset, offset + length));
      offset += length;
    }
    return frames;
  }
}

final class RingBacklogClient {
  RingBacklogClient({
    required this.deviceId,
    required this.ble,
    required this.sink,
    this.recordsPerRange = 1800,
    this.timeout = const Duration(seconds: 15),
  }) {
    if (recordsPerRange <= 0 || recordsPerRange > 1800) {
      throw RangeError.range(recordsPerRange, 1, 1800, 'recordsPerRange');
    }
  }

  final String deviceId;
  final RingStorageBle ble;
  final DurableRingSink sink;
  final int recordsPerRange;
  final Duration timeout;
  Future<int>? _inFlight;

  Future<int> importRange(int start, int count) {
    final active = _inFlight;
    if (active != null) return active;
    final operation = _importRange(start, count.clamp(1, recordsPerRange));
    _inFlight = operation;
    return operation.whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
  }

  Future<int> _importRange(int start, int count) async {
    final result = Completer<_ReceivedRange>();
    final advanced = Completer<void>();
    final bytes = <int>[];
    var crc = 0xffffffff;
    int? announcedStart;
    int? announcedCount;
    late final StreamSubscription<List<int>> subscription;
    subscription = ble.storageNotifications.listen((notification) {
      if (notification.isEmpty) return;
      final data = ByteData.sublistView(Uint8List.fromList(notification));
      switch (notification.first) {
        case 0x01:
          if (result.isCompleted && notification.length >= 2) {
            if (notification[1] == 0) {
              if (!advanced.isCompleted) advanced.complete();
            } else if (!advanced.isCompleted) {
              advanced.completeError(StateError('ring advance failed'));
            }
          }
        case RingBacklogProtocol.notifyReadBegin:
          if (result.isCompleted) return;
          if (notification.length < 13) {
            result.completeError(const FormatException('truncated read begin'));
            return;
          }
          announcedStart = data.getUint64(1, Endian.big);
          announcedCount = data.getUint32(9, Endian.big);
        case RingBacklogProtocol.notifyData:
          if (result.isCompleted) return;
          if (announcedStart == null) {
            result.completeError(
              const FormatException('data before read begin'),
            );
            return;
          }
          for (final byte in notification.skip(1)) {
            bytes.add(byte);
            crc ^= byte & 0xff;
            for (var bit = 0; bit < 8; bit++) {
              crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320;
            }
          }
        case RingBacklogProtocol.notifyDone:
          if (result.isCompleted) return;
          if (notification.length < 10) {
            result.completeError(const FormatException('truncated done'));
            return;
          }
          final status = data.getUint8(1);
          final next = data.getUint64(2, Endian.big);
          final expectedCrc = notification.length >= 14
              ? data.getUint32(10, Endian.big)
              : null;
          result.complete(
            _ReceivedRange(
              start: announcedStart,
              count: announcedCount,
              next: next,
              status: status,
              bytes: bytes,
              crcMatches:
                  expectedCrc == null ||
                  expectedCrc == ((crc ^ 0xffffffff) & 0xffffffff),
            ),
          );
      }
    });
    try {
      await ble.writeStorage(RingBacklogProtocol.readCommand(start, count));
      final received = await result.future.timeout(timeout);
      final records = received.validate(start, count);
      final frames = records
          .expand(RingBacklogProtocol.frames)
          .map(Uint8List.fromList)
          .toList(growable: false);
      if (frames.isEmpty) throw const FormatException('empty ring range');
      final timestamp = ByteData.sublistView(
        records.first,
      ).getUint32(0, Endian.big);
      await sink.importRange(
        DurableRingRange(
          sourceId: 'ring_${received.start}_${received.next}',
          deviceId: deviceId,
          startedAtMs: timestamp == 0
              ? DateTime.now().millisecondsSinceEpoch
              : timestamp * 1000,
          frames: frames,
        ),
      );
      await ble.writeStorage(RingBacklogProtocol.advanceCommand(received.next));
      await advanced.future.timeout(timeout);
      return received.next;
    } finally {
      await subscription.cancel();
    }
  }
}

final class _ReceivedRange {
  const _ReceivedRange({
    required this.start,
    required this.count,
    required this.next,
    required this.status,
    required this.bytes,
    required this.crcMatches,
  });

  final int? start;
  final int? count;
  final int next;
  final int status;
  final List<int> bytes;
  final bool crcMatches;

  List<Uint8List> validate(int requestedStart, int requestedCount) {
    if (status != 0 ||
        start != requestedStart ||
        count != requestedCount ||
        next != requestedStart + requestedCount ||
        bytes.length != requestedCount * RingBacklogProtocol.recordBytes ||
        !crcMatches) {
      throw const FormatException('incomplete ring range');
    }
    return List.generate(
      requestedCount,
      (index) => Uint8List.fromList(
        bytes.sublist(
          index * RingBacklogProtocol.recordBytes,
          (index + 1) * RingBacklogProtocol.recordBytes,
        ),
      ),
      growable: false,
    );
  }
}
