import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../random_id.dart';

/// How the audio bytes of a segment are delimited.
///
/// Opus packets are variable length and carry no length of their own, so a run
/// of them concatenated on disk cannot be split back into packets and cannot be
/// containerised for upload. Segments in such an encoding therefore store each
/// packet behind a big-endian uint16 length. Everything else is a fixed-width
/// or otherwise self-describing stream and is stored verbatim.
abstract final class CaptureWalFraming {
  static const raw = 'raw';
  static const len16 = 'len16';

  static String forEncoding(String encoding) =>
      encoding == 'opus' ? len16 : raw;
}

/// A sealed unit of captured audio waiting to be uploaded.
///
/// The [id] is generated once, before the first byte is written, and lives in
/// the file name. It is therefore stable across process death and is the
/// client-supplied idempotency key the transcription endpoint deduplicates on:
/// a retry after a dropped response re-sends the same id and cannot produce a
/// second transcription or a second charge.
final class CaptureWalSegment {
  const CaptureWalSegment({
    required this.id,
    required this.sequence,
    required this.deviceId,
    required this.audioStreamId,
    required this.encoding,
    required this.sampleRateHz,
    required this.channels,
    required this.startedAt,
    required this.gapBefore,
    required this.audioBytes,
    this.framing = CaptureWalFraming.raw,
  });

  /// Client-supplied idempotency key for the upload.
  final String id;

  /// Monotonic ring position. Ordering key for both upload and eviction.
  final int sequence;
  final String deviceId;

  /// The STT session this audio belonged to. A gap-recording restart mints a
  /// new one, so segments either side of a gap are never presented as a single
  /// continuous stream.
  final String audioStreamId;
  final String encoding;

  /// One of [CaptureWalFraming]. Older segments predate the field and are read
  /// back as [CaptureWalFraming.raw].
  final String framing;
  final int sampleRateHz;
  final int channels;
  final DateTime startedAt;

  /// True when a recorded discontinuity immediately precedes this segment.
  final bool gapBefore;
  final int audioBytes;
}

final class CaptureWalStats {
  const CaptureWalStats({
    required this.segments,
    required this.bytes,
    required this.oldest,
  });

  final int segments;
  final int bytes;
  final DateTime? oldest;
}

/// Bounded on-disk write-ahead log for pendant audio.
///
/// Every frame handed to the hub is also appended here, so audio that was in
/// flight when a packet dropped, the socket died, or the process was killed is
/// still on disk and can be uploaded later.
///
/// ## Storage layout
///
/// One file per segment under [directory]. The name carries the ordering and
/// the idempotency key: `<20-digit sequence>-<id>.seg` once sealed, `.open`
/// while still being appended to. Each file is a single JSON header line, a
/// newline, then the raw audio bytes in the pendant's own encoding.
///
/// ## Eviction policy
///
/// Sealed segments are evicted **oldest first** whenever either bound is
/// exceeded, and the bounds are re-applied on open, on every seal, and on
/// every append that crosses a segment boundary:
///
///  * **Age** — any sealed segment whose start time is older than [maxAge] is
///    deleted, whether or not the log is over its size bound. This is what
///    stops a phone that has been offline for days from holding audio that is
///    no longer worth transcribing.
///  * **Size** — while the sealed total exceeds [maxBytes], the oldest sealed
///    segment is deleted.
///
/// The segment currently being appended to is never evicted, but it is capped
/// at [maxSegmentBytes] and auto-sealed on reaching it, so total on-disk usage
/// is bounded by `maxBytes + maxSegmentBytes` and never grows without limit.
/// Eviction is silent data loss by design: the alternative — refusing to
/// record — loses the *newest* audio, which is the audio the user is most
/// likely to care about.
final class CaptureWal {
  CaptureWal._(
    this._now,
    this._nextSequence, {
    required this.directory,
    required this.maxBytes,
    required this.maxAge,
    required this.maxSegmentBytes,
  });

  static const defaultMaxBytes = 64 * 1024 * 1024;
  static const defaultMaxAge = Duration(hours: 48);
  static const defaultMaxSegmentBytes = 1024 * 1024;
  static const _sequenceDigits = 20;

  final Directory directory;
  final int maxBytes;
  final Duration maxAge;
  final int maxSegmentBytes;
  final DateTime Function() _now;

  int _nextSequence;
  _OpenSegment? _open;
  Future<void> _work = Future.value();

  /// Opens (creating if needed) the log at [directory].
  ///
  /// Any segment left `.open` by a previous process is sealed rather than
  /// discarded — the whole point of the log is that a killed process does not
  /// lose the audio it had already written — and the bounds are applied before
  /// the first new byte is accepted.
  static Future<CaptureWal> open({
    required Directory directory,
    int maxBytes = defaultMaxBytes,
    Duration maxAge = defaultMaxAge,
    int maxSegmentBytes = defaultMaxSegmentBytes,
    DateTime Function()? now,
  }) async {
    if (maxBytes <= 0 || maxSegmentBytes <= 0 || maxAge <= Duration.zero) {
      throw ArgumentError('CaptureWal bounds must be positive.');
    }
    await directory.create(recursive: true);
    var nextSequence = 0;
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      final sequence = _sequenceOf(name);
      if (sequence == null) continue;
      if (sequence >= nextSequence) nextSequence = sequence + 1;
      if (name.endsWith('.open')) {
        entity.renameSync(
          '${entity.parent.path}${Platform.pathSeparator}'
          '${name.substring(0, name.length - '.open'.length)}.seg',
        );
      }
    }
    final wal = CaptureWal._(
      now ?? DateTime.now,
      nextSequence,
      directory: directory,
      maxBytes: maxBytes,
      maxAge: maxAge,
      maxSegmentBytes: maxSegmentBytes,
    );
    await wal.evict();
    return wal;
  }

  /// Seals whatever is open and starts a new segment.
  Future<String> beginSegment({
    required String deviceId,
    required String audioStreamId,
    required String encoding,
    required int sampleRateHz,
    required int channels,
    bool gapBefore = false,
  }) {
    final id = randomId();
    final framing = CaptureWalFraming.forEncoding(encoding);
    return _serialize(() async {
      await _seal();
      final sequence = _nextSequence++;
      final header = <String, Object?>{
        'id': id,
        'sequence': sequence,
        'deviceId': deviceId,
        'audioStreamId': audioStreamId,
        'encoding': encoding,
        'framing': framing,
        'sampleRateHz': sampleRateHz,
        'channels': channels,
        'startedAtMs': _now().toUtc().millisecondsSinceEpoch,
        'gapBefore': gapBefore,
      };
      final file = File(_path(sequence, id, sealed: false));
      final sink = file.openWrite();
      sink.add(utf8.encode('${jsonEncode(header)}\n'));
      // Durability is the whole point: a header still sitting in the sink's
      // buffer when the process dies leaves an unreadable segment behind.
      await sink.flush();
      _open = _OpenSegment(
        id: id,
        sequence: sequence,
        file: file,
        sink: sink,
        framing: framing,
      );
      return id;
    });
  }

  /// Appends captured audio to the open segment. A no-op when no segment is
  /// open, so a caller that failed to start one never throws mid-capture.
  Future<void> append(Uint8List bytes) => _serialize(() async {
    final open = _open;
    if (open == null || bytes.isEmpty) return;
    if (open.framing == CaptureWalFraming.len16) {
      // A packet that cannot be described by the length prefix cannot be
      // recovered from the segment either, so it is refused rather than
      // written unframed and corrupting every packet after it.
      if (bytes.length > 0xffff) return;
      open.sink.add(
        Uint8List.fromList([bytes.length >> 8, bytes.length & 0xff]),
      );
      open.audioBytes += 2;
    }
    open.sink.add(bytes);
    // Flush every append. A killed process must lose at most the frame that
    // was in flight, not everything written since the segment opened.
    await open.sink.flush();
    open.audioBytes += bytes.length;
    if (open.audioBytes >= maxSegmentBytes) {
      await _seal();
      await _evict();
    }
  });

  /// Seals the open segment so it becomes uploadable, then re-applies bounds.
  Future<void> seal() => _serialize(() async {
    await _seal();
    await _evict();
  });

  /// Sealed segments, oldest first. The open segment is deliberately excluded:
  /// uploading a segment that is still growing would give the endpoint a
  /// partial body under an id that later means something longer.
  Future<List<CaptureWalSegment>> pending() =>
      _serialize(() async => _sealedSegments());

  /// The audio payload of [segment], or null when it has since been evicted.
  Future<Uint8List?> readAudio(CaptureWalSegment segment) =>
      _serialize(() async {
        final file = File(_path(segment.sequence, segment.id, sealed: true));
        if (!file.existsSync()) return null;
        final bytes = await file.readAsBytes();
        final split = bytes.indexOf(0x0a);
        if (split < 0) return null;
        return Uint8List.sublistView(bytes, split + 1);
      });

  /// Drops [segment] after a confirmed upload. Idempotent.
  Future<void> remove(CaptureWalSegment segment) => _serialize(() async {
    final file = File(_path(segment.sequence, segment.id, sealed: true));
    if (file.existsSync()) await file.delete();
  });

  Future<CaptureWalStats> stats() => _serialize(() async {
    final segments = _sealedSegments();
    return CaptureWalStats(
      segments: segments.length,
      bytes: segments.fold(0, (total, segment) => total + segment.audioBytes),
      oldest: segments.isEmpty ? null : segments.first.startedAt,
    );
  });

  /// Applies the age and size bounds. Returns the number of segments deleted.
  Future<int> evict() => _serialize(_evict);

  /// Seals the open segment and releases the file handle.
  Future<void> close() => _serialize(_seal);

  Future<int> _evict() async {
    var removed = 0;
    final cutoff = _now().toUtc().subtract(maxAge);
    final segments = _sealedSegments();
    final survivors = <CaptureWalSegment>[];
    for (final segment in segments) {
      if (segment.startedAt.isBefore(cutoff)) {
        await _delete(segment);
        removed += 1;
      } else {
        survivors.add(segment);
      }
    }
    var total = survivors.fold(0, (sum, s) => sum + s.audioBytes);
    var index = 0;
    while (total > maxBytes && index < survivors.length) {
      final segment = survivors[index++];
      await _delete(segment);
      total -= segment.audioBytes;
      removed += 1;
    }
    return removed;
  }

  Future<void> _delete(CaptureWalSegment segment) async {
    final file = File(_path(segment.sequence, segment.id, sealed: true));
    if (file.existsSync()) await file.delete();
  }

  Future<void> _seal() async {
    final open = _open;
    if (open == null) return;
    _open = null;
    await open.sink.flush();
    await open.sink.close();
    await open.file.rename(_path(open.sequence, open.id, sealed: true));
  }

  List<CaptureWalSegment> _sealedSegments() {
    final segments = <CaptureWalSegment>[];
    if (!directory.existsSync()) return segments;
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (!name.endsWith('.seg')) continue;
      final segment = _read(entity);
      if (segment != null) segments.add(segment);
    }
    segments.sort((a, b) => a.sequence.compareTo(b.sequence));
    return segments;
  }

  CaptureWalSegment? _read(File file) {
    final Uint8List bytes;
    try {
      bytes = file.readAsBytesSync();
    } on FileSystemException {
      return null;
    }
    final split = bytes.indexOf(0x0a);
    if (split <= 0) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(Uint8List.sublistView(bytes, 0, split)));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final id = decoded['id'];
    final sequence = decoded['sequence'];
    final deviceId = decoded['deviceId'];
    final audioStreamId = decoded['audioStreamId'];
    final encoding = decoded['encoding'];
    final framing = decoded['framing'];
    final sampleRateHz = decoded['sampleRateHz'];
    final channels = decoded['channels'];
    final startedAtMs = decoded['startedAtMs'];
    if (id is! String ||
        sequence is! int ||
        deviceId is! String ||
        audioStreamId is! String ||
        encoding is! String ||
        sampleRateHz is! int ||
        channels is! int ||
        startedAtMs is! int) {
      return null;
    }
    return CaptureWalSegment(
      id: id,
      sequence: sequence,
      deviceId: deviceId,
      audioStreamId: audioStreamId,
      encoding: encoding,
      framing: framing is String ? framing : CaptureWalFraming.raw,
      sampleRateHz: sampleRateHz,
      channels: channels,
      startedAt: DateTime.fromMillisecondsSinceEpoch(startedAtMs, isUtc: true),
      gapBefore: decoded['gapBefore'] == true,
      audioBytes: bytes.length - split - 1,
    );
  }

  String _path(int sequence, String id, {required bool sealed}) =>
      '${directory.path}${Platform.pathSeparator}'
      '${sequence.toString().padLeft(_sequenceDigits, '0')}-$id'
      '${sealed ? '.seg' : '.open'}';

  /// All file work runs on one chain: appends, seals and eviction share the
  /// open handle and the sequence counter, and interleaving them would both
  /// corrupt a segment and lose the ordering the ring depends on.
  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _work.then((_) => action());
    _work = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static String _basename(String path) {
    final index = path.lastIndexOf(Platform.pathSeparator);
    return index < 0 ? path : path.substring(index + 1);
  }

  static int? _sequenceOf(String name) {
    if (name.length < _sequenceDigits + 1) return null;
    return int.tryParse(name.substring(0, _sequenceDigits));
  }
}

final class _OpenSegment {
  _OpenSegment({
    required this.id,
    required this.sequence,
    required this.file,
    required this.sink,
    required this.framing,
  });

  final String id;
  final int sequence;
  final File file;
  final IOSink sink;
  final String framing;
  int audioBytes = 0;
}
