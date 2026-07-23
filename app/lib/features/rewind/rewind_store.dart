import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../storage/omi_directory.dart';
import 'rewind_models.dart';

/// The on-disk timeline: JPEG frames under `~/.omi/rewind/frames`, and a
/// newline-delimited index beside them. Retention is enforced on every write,
/// oldest first, against both bounds — age and total bytes — and enforcing it
/// deletes the file, it does not merely drop the index row. "Deleted" here
/// means the bytes are gone.
final class RewindStore {
  RewindStore(this.root);

  final Directory root;

  static const _indexName = 'index.jsonl';
  static const _framesDirName = 'frames';

  final List<RewindFrame> _frames = [];
  int _totalBytes = 0;
  bool _loaded = false;

  static Future<RewindStore> open() async {
    final base = await omiDataDirectory();
    final store = RewindStore(
      Directory('${base.path}${Platform.pathSeparator}rewind'),
    );
    await store.load();
    return store;
  }

  File get indexFile =>
      File('${root.path}${Platform.pathSeparator}$_indexName');

  Directory get framesDirectory =>
      Directory('${root.path}${Platform.pathSeparator}$_framesDirName');

  /// Frames oldest first.
  List<RewindFrame> get frames => List.unmodifiable(_frames);

  int get totalBytes => _totalBytes;

  File fileFor(RewindFrame frame) =>
      File('${root.path}${Platform.pathSeparator}${frame.relativePath}');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    await root.create(recursive: true);
    if (!await indexFile.exists()) return;
    final lines = await indexFile.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      final frame = RewindFrame.fromJson(decoded);
      if (frame == null) continue;
      _frames.add(frame);
      _totalBytes += frame.bytes;
    }
    _frames.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
  }

  /// Writes one frame and returns it, after enforcing [retention]. The caller
  /// owns the encoded bytes; nothing is decoded here.
  Future<RewindFrame> write({
    required Uint8List jpeg,
    required DateTime capturedAt,
    required String hash,
    required RewindRetention retention,
    String? appName,
    String? bundleId,
    String? windowTitle,
    String? ocrText,
  }) async {
    await load();
    final day = _day(capturedAt);
    final relative =
        '$_framesDirName/$day/${capturedAt.millisecondsSinceEpoch}.jpg';
    final file = File('${root.path}${Platform.pathSeparator}$relative');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(jpeg, flush: true);
    final frame = RewindFrame(
      capturedAt: capturedAt,
      relativePath: relative,
      bytes: jpeg.length,
      hash: hash,
      appName: appName,
      bundleId: bundleId,
      windowTitle: windowTitle,
      ocrText: ocrText,
    );
    _frames.add(frame);
    _totalBytes += frame.bytes;
    await indexFile.writeAsString(
      '${jsonEncode(frame.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
    await enforce(retention, now: capturedAt);
    return frame;
  }

  /// Applies both retention bounds, deleting oldest first. Returns the number
  /// of frames removed.
  Future<int> enforce(RewindRetention retention, {DateTime? now}) async {
    await load();
    final cutoff = (now ?? DateTime.now()).subtract(retention.maxAge);
    var removed = 0;
    while (_frames.isNotEmpty &&
        (_frames.first.capturedAt.isBefore(cutoff) ||
            _totalBytes > retention.maxBytes)) {
      final frame = _frames.removeAt(0);
      _totalBytes -= frame.bytes;
      await _deleteFile(frame);
      removed++;
    }
    if (removed > 0) {
      await _rewriteIndex();
      await _pruneEmptyDays();
    }
    return removed;
  }

  /// Searches the recognized text, app names and window titles. Newest first,
  /// and never more than [limit] results. Matching happens entirely here —
  /// nothing about the query or the timeline leaves the machine.
  List<RewindFrame> search(String query, {int limit = 200}) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final results = <RewindFrame>[];
    for (var index = _frames.length - 1; index >= 0; index--) {
      final frame = _frames[index];
      final haystack = [
        frame.ocrText,
        frame.appName,
        frame.windowTitle,
      ].whereType<String>().join('\n').toLowerCase();
      if (haystack.contains(needle)) results.add(frame);
      if (results.length >= limit) break;
    }
    return results;
  }

  /// Deletes a single frame — the timeline's per-frame delete.
  Future<void> delete(RewindFrame frame) async {
    await load();
    if (!_frames.remove(frame)) return;
    _totalBytes -= frame.bytes;
    await _deleteFile(frame);
    await _rewriteIndex();
    await _pruneEmptyDays();
  }

  /// Deletes every frame captured in [range] — "forget the last hour".
  Future<int> deleteRange(DateTime from, DateTime to) async {
    await load();
    final doomed = _frames
        .where(
          (frame) =>
              !frame.capturedAt.isBefore(from) && !frame.capturedAt.isAfter(to),
        )
        .toList(growable: false);
    for (final frame in doomed) {
      _frames.remove(frame);
      _totalBytes -= frame.bytes;
      await _deleteFile(frame);
    }
    if (doomed.isNotEmpty) {
      await _rewriteIndex();
      await _pruneEmptyDays();
    }
    return doomed.length;
  }

  /// Removes every frame and the index itself.
  Future<void> deleteAll() async {
    await load();
    _frames.clear();
    _totalBytes = 0;
    if (await framesDirectory.exists()) {
      await framesDirectory.delete(recursive: true);
    }
    if (await indexFile.exists()) await indexFile.delete();
  }

  Future<void> _deleteFile(RewindFrame frame) async {
    final file = fileFor(frame);
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A frame that is already gone is the state we wanted anyway.
    }
  }

  Future<void> _rewriteIndex() async {
    final buffer = StringBuffer();
    for (final frame in _frames) {
      buffer.writeln(jsonEncode(frame.toJson()));
    }
    await indexFile.writeAsString(buffer.toString(), flush: true);
  }

  Future<void> _pruneEmptyDays() async {
    if (!await framesDirectory.exists()) return;
    await for (final entry in framesDirectory.list()) {
      if (entry is! Directory) continue;
      final empty = await entry.list().isEmpty;
      if (empty) await entry.delete();
    }
  }

  static String _day(DateTime at) {
    final month = at.month.toString().padLeft(2, '0');
    final day = at.day.toString().padLeft(2, '0');
    return '${at.year}-$month-$day';
  }
}
