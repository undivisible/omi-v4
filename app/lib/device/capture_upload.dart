import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../api/worker_http.dart';
import 'capture_wal.dart';

/// What the server did with an uploaded segment.
enum CaptureUploadOutcome {
  /// Stored and queued for transcription. The segment can be deleted.
  accepted,

  /// The idempotency key was already known, so this was a retry of a request
  /// the server had already processed. Indistinguishable from [accepted] for
  /// the client, and deliberately so — that is what makes retry-after-drop
  /// safe.
  duplicate,

  /// A transient failure (offline, 5xx, 429). Keep the segment and try again.
  retry,

  /// The server refused this segment and will keep refusing it. Dropping it is
  /// the only way to stop it blocking every segment behind it in the ring.
  rejected,
}

final class CaptureUploadResult {
  const CaptureUploadResult(this.outcome, {this.message});

  final CaptureUploadOutcome outcome;
  final String? message;

  bool get done =>
      outcome == CaptureUploadOutcome.accepted ||
      outcome == CaptureUploadOutcome.duplicate;
}

/// The one seam between the write-ahead log and the server.
///
/// The contract is deliberately narrow: one sealed segment, one client-chosen
/// idempotency key, one outcome. The segment's own id is the key, so anything
/// that honours a caller-supplied message id can be dropped in here without the
/// log or the uploader changing.
abstract interface class CaptureUploadTransport {
  Future<CaptureUploadResult> upload(
    CaptureWalSegment segment,
    Uint8List audio,
  );
}

/// A sealed segment repackaged into something a transcription model will
/// actually accept, plus the exact duration it covers.
final class CaptureUploadPayload {
  const CaptureUploadPayload({
    required this.format,
    required this.bytes,
    required this.durationSeconds,
  });

  /// The container name the endpoint is given: `wav` or `ogg`.
  final String format;
  final Uint8List bytes;
  final int durationSeconds;
}

/// Repackages a segment's raw payload into an uploadable container, or returns
/// null when it cannot be — an unknown encoding, an Opus segment written before
/// the log recorded packet boundaries, or an empty payload.
///
/// The pendant streams bare Opus packets (16 kHz mono, 20 ms frames, 32 kbps —
/// `firmware/BLE_CONTRACTS.md` §2.2) and the log stores them in that encoding.
/// No transcription model takes bare Opus packets, so they are Ogg-encapsulated
/// here, on the phone, rather than shipped to an endpoint that would reject
/// every one of them. PCM is likewise wrapped in a WAV header.
CaptureUploadPayload? captureUploadPayload(
  CaptureWalSegment segment,
  Uint8List audio,
) {
  if (audio.isEmpty) return null;
  final channels = segment.channels < 1 ? 1 : segment.channels;
  final sampleRateHz = segment.sampleRateHz;
  if (sampleRateHz <= 0) return null;
  switch (segment.encoding) {
    case 'pcmS16Le':
    case 'pcmU8':
      final bitsPerSample = segment.encoding == 'pcmU8' ? 8 : 16;
      final bytesPerSecond = sampleRateHz * channels * (bitsPerSample ~/ 8);
      return CaptureUploadPayload(
        format: 'wav',
        bytes: _wav(
          audio,
          sampleRateHz: sampleRateHz,
          channels: channels,
          bitsPerSample: bitsPerSample,
        ),
        durationSeconds: _atLeastOneSecond(audio.length, bytesPerSecond),
      );
    case 'opus':
      if (segment.framing != CaptureWalFraming.len16) return null;
      final packets = _unframe(audio);
      if (packets.isEmpty) return null;
      return CaptureUploadPayload(
        format: 'ogg',
        bytes: _oggOpus(
          packets,
          sampleRateHz: sampleRateHz,
          channels: channels,
        ),
        durationSeconds: _atLeastOneSecond(
          packets.length * _opusFrameMs,
          Duration.millisecondsPerSecond,
        ),
      );
    default:
      return null;
  }
}

int _atLeastOneSecond(int quantity, int perSecond) {
  final seconds = (quantity + perSecond - 1) ~/ perSecond;
  return seconds < 1 ? 1 : seconds;
}

/// Splits a `len16`-framed payload back into packets. A truncated tail — the
/// last frame a killed process was mid-write on — is dropped rather than
/// failing the whole segment.
List<Uint8List> _unframe(Uint8List audio) {
  final packets = <Uint8List>[];
  var offset = 0;
  while (offset + 2 <= audio.length) {
    final length = (audio[offset] << 8) | audio[offset + 1];
    if (length == 0 || offset + 2 + length > audio.length) break;
    packets.add(Uint8List.sublistView(audio, offset + 2, offset + 2 + length));
    offset += 2 + length;
  }
  return packets;
}

/// Little-endian integer of [bytes] width. The 8-byte case is written as two
/// 32-bit halves so it does not depend on 64-bit integer support.
Uint8List _le(int value, int bytes) {
  final data = ByteData(bytes);
  switch (bytes) {
    case 2:
      data.setUint16(0, value, Endian.little);
    case 4:
      data.setUint32(0, value, Endian.little);
    default:
      data.setUint32(0, value & 0xffffffff, Endian.little);
      data.setUint32(4, value ~/ 0x100000000, Endian.little);
  }
  return data.buffer.asUint8List();
}

Uint8List _wav(
  Uint8List samples, {
  required int sampleRateHz,
  required int channels,
  required int bitsPerSample,
}) {
  final blockAlign = channels * (bitsPerSample ~/ 8);
  final builder = BytesBuilder()
    ..add(ascii.encode('RIFF'))
    ..add(_le(36 + samples.length, 4))
    ..add(ascii.encode('WAVEfmt '))
    ..add(_le(16, 4))
    ..add(_le(1, 2))
    ..add(_le(channels, 2))
    ..add(_le(sampleRateHz, 4))
    ..add(_le(sampleRateHz * blockAlign, 4))
    ..add(_le(blockAlign, 2))
    ..add(_le(bitsPerSample, 2))
    ..add(ascii.encode('data'))
    ..add(_le(samples.length, 4))
    ..add(samples);
  return builder.takeBytes();
}

/// The pendant's frame length. Fixed in firmware at 320 samples of 16 kHz
/// audio; Ogg Opus granule positions are always counted at 48 kHz.
const _opusFrameMs = 20;
const _opusFrameGranule = 960;
const _opusSerial = 0x4f4d4901;
const _oggMaxLaces = 255;
const _oggMaxPageBytes = 4096;

// Ogg's CRC is the unreflected CRC-32/MPEG-2 polynomial with a zero initial
// value and no final inversion, computed over the page with its own checksum
// field zeroed.
final _oggCrcTable = List<int>.generate(256, (index) {
  var value = index << 24;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 0x80000000) != 0
        ? ((value << 1) ^ 0x04c11db7) & 0xffffffff
        : (value << 1) & 0xffffffff;
  }
  return value;
}, growable: false);

int _oggCrc(Uint8List page) {
  var crc = 0;
  for (final byte in page) {
    crc = ((crc << 8) & 0xffffffff) ^ _oggCrcTable[((crc >> 24) & 0xff) ^ byte];
  }
  return crc;
}

Uint8List _oggPage(
  List<Uint8List> packets, {
  required int headerType,
  required int granule,
  required int page,
}) {
  final laces = <int>[];
  for (final packet in packets) {
    var remaining = packet.length;
    while (remaining >= 255) {
      laces.add(255);
      remaining -= 255;
    }
    laces.add(remaining);
  }
  final builder = BytesBuilder()
    ..add(ascii.encode('OggS'))
    ..addByte(0)
    ..addByte(headerType)
    ..add(_le(granule, 8))
    ..add(_le(_opusSerial, 4))
    ..add(_le(page, 4))
    ..add(_le(0, 4))
    ..addByte(laces.length)
    ..add(Uint8List.fromList(laces));
  for (final packet in packets) {
    builder.add(packet);
  }
  final bytes = builder.takeBytes();
  bytes.setRange(22, 26, _le(_oggCrc(bytes), 4));
  return bytes;
}

Uint8List _oggOpus(
  List<Uint8List> packets, {
  required int sampleRateHz,
  required int channels,
}) {
  final head = BytesBuilder()
    ..add(ascii.encode('OpusHead'))
    ..addByte(1)
    ..addByte(channels)
    ..add(_le(0, 2))
    ..add(_le(sampleRateHz, 4))
    ..add(_le(0, 2))
    ..addByte(0);
  final vendor = ascii.encode('omi');
  final tags = BytesBuilder()
    ..add(ascii.encode('OpusTags'))
    ..add(_le(vendor.length, 4))
    ..add(vendor)
    ..add(_le(0, 4));
  final output = BytesBuilder()
    ..add(_oggPage([head.takeBytes()], headerType: 0x02, granule: 0, page: 0))
    ..add(_oggPage([tags.takeBytes()], headerType: 0, granule: 0, page: 1));
  var page = 2;
  var granule = 0;
  var index = 0;
  while (index < packets.length) {
    final batch = <Uint8List>[];
    var laces = 0;
    var bytes = 0;
    while (index < packets.length) {
      final packet = packets[index];
      final packetLaces = packet.length ~/ 255 + 1;
      if (batch.isNotEmpty &&
          (laces + packetLaces > _oggMaxLaces ||
              bytes + packet.length > _oggMaxPageBytes)) {
        break;
      }
      batch.add(packet);
      laces += packetLaces;
      bytes += packet.length;
      index += 1;
    }
    granule += batch.length * _opusFrameGranule;
    output.add(
      _oggPage(
        batch,
        headerType: index >= packets.length ? 0x04 : 0,
        granule: granule,
        page: page,
      ),
    );
    page += 1;
  }
  return output.takeBytes();
}

/// Posts sealed segments to the Worker's batch transcription endpoint.
///
/// The segment id travels in the body as `clientMessageId`, which is what
/// `POST /api/v1/speech/transcriptions` derives its admission reservation from:
/// a retry after a dropped response replays the stored transcript instead of
/// calling upstream, so it neither re-charges the account nor duplicates the
/// segment. The raw BLE device id never leaves the phone — it is SHA-256'd
/// first, exactly as the live managed-STT path does.
final class WorkerCaptureUploadTransport implements CaptureUploadTransport {
  const WorkerCaptureUploadTransport(this._client, {this.path = defaultPath});

  static const defaultPath = '/api/v1/speech/transcriptions';

  final WorkerHttpClient _client;
  final String path;

  @override
  Future<CaptureUploadResult> upload(
    CaptureWalSegment segment,
    Uint8List audio,
  ) async {
    final payload = captureUploadPayload(segment, audio);
    if (payload == null) {
      // Nothing a later pass could do differently, and keeping it would block
      // every segment behind it.
      return const CaptureUploadResult(
        CaptureUploadOutcome.rejected,
        message: 'Segment cannot be packaged for upload.',
      );
    }
    final ({int statusCode, Object? body}) response;
    try {
      response = await _client.send(
        method: 'POST',
        path: path,
        body: {
          'clientMessageId': segment.id,
          'format': payload.format,
          'durationSeconds': payload.durationSeconds,
          'audio': base64Encode(payload.bytes),
          // Provenance the evidence model needs: which stream the audio came
          // from, and whether a recorded discontinuity precedes it.
          'deviceId': sha256.convert(utf8.encode(segment.deviceId)).toString(),
          'audioStreamId': segment.audioStreamId,
          'gapBefore': segment.gapBefore,
          'startedAt': segment.startedAt.toUtc().toIso8601String(),
        },
      );
    } on WorkerAuthenticationException catch (error) {
      // Signed out or an expired token: the audio is still worth keeping.
      return CaptureUploadResult(
        CaptureUploadOutcome.retry,
        message: error.message,
      );
    } catch (error) {
      return CaptureUploadResult(
        CaptureUploadOutcome.retry,
        message: error.toString(),
      );
    }
    final status = response.statusCode;
    final body = response.body;
    final message = body is Map<String, Object?> && body['error'] is String
        ? body['error']! as String
        : null;
    if (status == 200 || status == 201 || status == 202 || status == 204) {
      // A server that recognises the key says so explicitly; either way the
      // client is finished with the segment.
      final duplicate =
          body is Map<String, Object?> &&
          (body['idempotentReplay'] == true || body['duplicate'] == true);
      return CaptureUploadResult(
        duplicate
            ? CaptureUploadOutcome.duplicate
            : CaptureUploadOutcome.accepted,
        message: message,
      );
    }
    if (status == 409) {
      // Two different 409s: the same id still being processed, which resolves
      // itself, and the same id carrying different audio, which never will.
      return CaptureUploadResult(
        message != null && message.contains('in progress')
            ? CaptureUploadOutcome.retry
            : CaptureUploadOutcome.rejected,
        message: message,
      );
    }
    if (status == 401 ||
        status == 403 ||
        status == 408 ||
        status == 425 ||
        status == 429 ||
        status >= 500) {
      // Entitlement and auth can come back; the audio outlives both.
      return CaptureUploadResult(CaptureUploadOutcome.retry, message: message);
    }
    return CaptureUploadResult(
      CaptureUploadOutcome.rejected,
      message: message ?? 'Upload rejected ($status)',
    );
  }
}

/// A transport for builds where the endpoint is not reachable. Every segment
/// stays in the log until it ages or size-evicts out; nothing is ever silently
/// discarded because the upload route is missing.
final class UnavailableCaptureUploadTransport
    implements CaptureUploadTransport {
  const UnavailableCaptureUploadTransport();

  @override
  Future<CaptureUploadResult> upload(
    CaptureWalSegment segment,
    Uint8List audio,
  ) async => const CaptureUploadResult(
    CaptureUploadOutcome.retry,
    message: 'Batch transcription upload is not configured.',
  );
}

extension CaptureUploadSegment on CaptureUploadTransport {
  Future<CaptureUploadResult> uploadSegment(
    CaptureWalSegment segment,
    Uint8List audio,
  ) => upload(segment, audio);
}
