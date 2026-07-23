import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/device/capture_upload.dart';
import 'package:omi/device/capture_wal.dart';
import 'package:omi/device/capture_wal_uploader.dart';

Uint8List _bytes(int length, [int fill = 7]) =>
    Uint8List.fromList(List.filled(length, fill));

Future<CaptureWal> _open(
  Directory directory, {
  int maxBytes = 4096,
  Duration maxAge = const Duration(hours: 1),
  int maxSegmentBytes = 1024,
  DateTime Function()? now,
}) => CaptureWal.open(
  directory: directory,
  maxBytes: maxBytes,
  maxAge: maxAge,
  maxSegmentBytes: maxSegmentBytes,
  now: now,
);

Future<void> _write(
  CaptureWal wal,
  Uint8List bytes, {
  String streamId = 'stream-1',
}) async {
  await wal.beginSegment(
    deviceId: 'device-1',
    audioStreamId: streamId,
    encoding: 'pcmU8',
    sampleRateHz: 8000,
    channels: 1,
  );
  await wal.append(bytes);
  await wal.seal();
}

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('omi-wal-test');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  group('bounds and eviction', () {
    test(
      'keeps the newest segments and evicts the oldest over maxBytes',
      () async {
        final wal = await _open(
          directory,
          maxBytes: 900,
          maxSegmentBytes: 4096,
        );
        for (var index = 0; index < 5; index++) {
          await _write(wal, _bytes(300, index));
        }
        final pending = await wal.pending();
        // 5 * 300 = 1500 bytes written; the 900-byte bound leaves the newest 3.
        expect(pending.length, 3);
        expect(pending.map((segment) => segment.audioBytes), everyElement(300));
        final first = await wal.readAudio(pending.first);
        expect(
          first!.first,
          2,
          reason: 'segments 0 and 1 evicted oldest first',
        );
        final stats = await wal.stats();
        expect(stats.bytes, lessThanOrEqualTo(900));
        await wal.close();
      },
    );

    test('evicts by age even when well under the size bound', () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final wal = await _open(
        directory,
        maxBytes: 1 << 20,
        maxAge: const Duration(hours: 2),
        now: () => clock,
      );
      await _write(wal, _bytes(64));
      clock = clock.add(const Duration(hours: 3));
      await _write(wal, _bytes(64));
      final pending = await wal.pending();
      expect(pending.length, 1);
      expect(pending.single.startedAt, clock);
      await wal.close();
    });

    test('never grows without limit while offline for days', () async {
      var clock = DateTime.utc(2026, 1, 1);
      final wal = await _open(
        directory,
        maxBytes: 2048,
        maxAge: const Duration(days: 2),
        maxSegmentBytes: 512,
        now: () => clock,
      );
      // Three days of capture with nothing ever uploaded.
      for (var minute = 0; minute < 72 * 6; minute++) {
        clock = clock.add(const Duration(minutes: 10));
        await wal.beginSegment(
          deviceId: 'device-1',
          audioStreamId: 'stream-$minute',
          encoding: 'pcmU8',
          sampleRateHz: 8000,
          channels: 1,
        );
        await wal.append(_bytes(600));
      }
      await wal.seal();
      final stats = await wal.stats();
      expect(stats.bytes, lessThanOrEqualTo(2048 + 600));
      final onDisk = directory.listSync().whereType<File>().fold<int>(
        0,
        (total, file) => total + file.lengthSync(),
      );
      expect(onDisk, lessThan(8192));
      await wal.close();
    });

    test('auto-seals the open segment at maxSegmentBytes', () async {
      final wal = await _open(directory, maxSegmentBytes: 100);
      await wal.beginSegment(
        deviceId: 'device-1',
        audioStreamId: 'stream-1',
        encoding: 'pcmU8',
        sampleRateHz: 8000,
        channels: 1,
      );
      await wal.append(_bytes(150));
      expect((await wal.pending()).length, 1);
      await wal.close();
    });
  });

  group('survives process death', () {
    test('seals an unclosed segment on reopen and keeps its audio', () async {
      final first = await _open(directory);
      await first.beginSegment(
        deviceId: 'device-1',
        audioStreamId: 'stream-1',
        encoding: 'pcmU8',
        sampleRateHz: 8000,
        channels: 1,
        gapBefore: true,
      );
      await first.append(_bytes(48, 3));
      // No seal, no close: the process died here.

      final second = await _open(directory);
      final pending = await second.pending();
      expect(pending.length, 1);
      expect(pending.single.audioBytes, 48);
      expect(pending.single.gapBefore, isTrue);
      expect(pending.single.audioStreamId, 'stream-1');
      expect((await second.readAudio(pending.single))!.first, 3);
      await second.close();
    });

    test('keeps segment ids stable across a reopen', () async {
      final first = await _open(directory);
      await _write(first, _bytes(32));
      final before = (await first.pending()).single.id;
      await first.close();

      final second = await _open(directory);
      expect((await second.pending()).single.id, before);
      await second.close();
    });

    test('does not reuse a sequence number after a restart', () async {
      final first = await _open(directory);
      await _write(first, _bytes(32));
      await first.close();

      final second = await _open(directory);
      await _write(second, _bytes(32));
      final sequences = (await second.pending())
          .map((segment) => segment.sequence)
          .toList();
      expect(sequences, [0, 1]);
      await second.close();
    });
  });

  group('idempotent upload', () {
    test('a retry after a dropped response reuses the same key', () async {
      final wal = await _open(directory);
      await _write(wal, _bytes(32));
      final transport = _FakeUploadTransport()
        ..outcomes.addAll([
          CaptureUploadOutcome.retry,
          CaptureUploadOutcome.duplicate,
        ]);
      final uploader = CaptureWalUploader(
        wal: wal,
        transport: transport,
        maxAttemptsPerPass: 2,
      );
      await uploader.drain();
      expect(transport.keys.length, 2);
      expect(transport.keys.first, transport.keys.last);
      expect(await wal.pending(), isEmpty);
      uploader.dispose();
      await wal.close();
    });

    test('a duplicate is treated as done and the segment is dropped', () async {
      final wal = await _open(directory);
      await _write(wal, _bytes(32));
      final transport = _FakeUploadTransport()
        ..outcomes.add(CaptureUploadOutcome.duplicate);
      final uploader = CaptureWalUploader(wal: wal, transport: transport);
      await uploader.drain();
      expect(await wal.pending(), isEmpty);
      uploader.dispose();
      await wal.close();
    });

    test('a retryable failure keeps every segment for the next pass', () async {
      final wal = await _open(directory);
      await _write(wal, _bytes(32));
      await _write(wal, _bytes(32));
      final transport = _FakeUploadTransport();
      final uploader = CaptureWalUploader(
        wal: wal,
        transport: transport,
        maxAttemptsPerPass: 1,
      );
      await uploader.drain();
      expect((await wal.pending()).length, 2);

      transport.outcomes.addAll([
        CaptureUploadOutcome.accepted,
        CaptureUploadOutcome.accepted,
      ]);
      expect(await uploader.drain(), 2);
      expect(await wal.pending(), isEmpty);
      uploader.dispose();
      await wal.close();
    });

    test('the pending count drops to zero after a successful pass', () async {
      final wal = await _open(directory);
      await _write(wal, _bytes(32));
      await _write(wal, _bytes(32));
      final transport = _FakeUploadTransport()
        ..outcomes.addAll([
          CaptureUploadOutcome.accepted,
          CaptureUploadOutcome.accepted,
        ]);
      final uploader = CaptureWalUploader(wal: wal, transport: transport);
      expect(await uploader.drain(), 2);
      expect(uploader.pendingListenable.value, 0);
      uploader.dispose();
      await wal.close();
    });

    test('uploads oldest first', () async {
      final wal = await _open(directory);
      await _write(wal, _bytes(8, 1), streamId: 'a');
      await _write(wal, _bytes(8, 2), streamId: 'b');
      final transport = _FakeUploadTransport()
        ..outcomes.addAll([
          CaptureUploadOutcome.accepted,
          CaptureUploadOutcome.accepted,
        ]);
      final uploader = CaptureWalUploader(wal: wal, transport: transport);
      await uploader.drain();
      expect(transport.streams, ['a', 'b']);
      uploader.dispose();
      await wal.close();
    });

    test('a permanently rejected segment stops blocking the queue', () async {
      final wal = await _open(directory);
      await _write(wal, _bytes(8, 1), streamId: 'a');
      await _write(wal, _bytes(8, 2), streamId: 'b');
      final transport = _FakeUploadTransport()
        ..outcomes.addAll([
          CaptureUploadOutcome.rejected,
          CaptureUploadOutcome.accepted,
        ]);
      final uploader = CaptureWalUploader(wal: wal, transport: transport);
      expect(await uploader.drain(), 1);
      expect(await wal.pending(), isEmpty);
      uploader.dispose();
      await wal.close();
    });
  });
}

final class _FakeUploadTransport implements CaptureUploadTransport {
  final outcomes = <CaptureUploadOutcome>[];
  final keys = <String>[];
  final streams = <String>[];

  @override
  Future<CaptureUploadResult> upload(
    CaptureWalSegment segment,
    Uint8List audio,
  ) async {
    keys.add(segment.id);
    if (streams.isEmpty || streams.last != segment.audioStreamId) {
      streams.add(segment.audioStreamId);
    }
    final outcome = outcomes.isEmpty
        ? CaptureUploadOutcome.retry
        : outcomes.removeAt(0);
    return CaptureUploadResult(outcome);
  }
}
