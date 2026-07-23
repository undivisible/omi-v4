import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/capture_upload.dart';
import 'package:omi/device/capture_wal.dart';

CaptureWalSegment _segment({
  String encoding = 'opus',
  String framing = CaptureWalFraming.len16,
  int sampleRateHz = 16000,
  bool gapBefore = false,
}) => CaptureWalSegment(
  id: 'a' * 32,
  sequence: 3,
  deviceId: 'AA:BB:CC:DD:EE:FF',
  audioStreamId: 'omi-AA:BB:CC-1712345678901234',
  encoding: encoding,
  framing: framing,
  sampleRateHz: sampleRateHz,
  channels: 1,
  startedAt: DateTime.utc(2026, 7, 23, 9, 15),
  gapBefore: gapBefore,
  audioBytes: 0,
);

/// The on-disk shape of a `len16` segment: each Opus packet behind a
/// big-endian uint16 length.
Uint8List _framed(List<int> lengths) {
  final builder = BytesBuilder();
  for (var index = 0; index < lengths.length; index++) {
    final length = lengths[index];
    builder.add(Uint8List.fromList([length >> 8, length & 0xff]));
    builder.add(Uint8List.fromList(List.filled(length, index + 1)));
  }
  return builder.takeBytes();
}

String _tag(Uint8List bytes, int offset, int length) =>
    ascii.decode(Uint8List.sublistView(bytes, offset, offset + length));

void main() {
  group('packaging a sealed segment', () {
    test('wraps framed Opus packets in an Ogg stream', () {
      final payload = captureUploadPayload(_segment(), _framed([60, 57, 62]));

      expect(payload, isNotNull);
      expect(payload!.format, 'ogg');
      // Three 20 ms frames round up to one second of reservable audio.
      expect(payload.durationSeconds, 1);
      expect(_tag(payload.bytes, 0, 4), 'OggS');
      expect(_tag(payload.bytes, 28, 8), 'OpusHead');
      expect(payload.bytes.length, greaterThan(60 + 57 + 62));
      // The identification header declares the pendant's own mono 16 kHz
      // stream.
      expect(payload.bytes[37], 1);
      final rate = ByteData.sublistView(
        payload.bytes,
        40,
        44,
      ).getUint32(0, Endian.little);
      expect(rate, 16000);
    });

    test('opens the comment header and closes the stream', () {
      final payload = captureUploadPayload(_segment(), _framed([40, 40]))!;
      final text = latin1.decode(payload.bytes);

      expect(text.contains('OpusTags'), isTrue);
      // Exactly one begin-of-stream page and one end-of-stream page.
      expect(payload.bytes[5], 0x02);
      final pages = <int>[];
      for (var index = text.indexOf('OggS'); index >= 0;) {
        pages.add(index);
        index = text.indexOf('OggS', index + 4);
      }
      expect(pages.length, 3);
      expect(payload.bytes[pages.last + 5], 0x04);
    });

    test('wraps PCM in a WAV header and measures it from the sample rate', () {
      final payload = captureUploadPayload(
        _segment(encoding: 'pcmS16Le', framing: CaptureWalFraming.raw),
        Uint8List(32000 * 3),
      );

      expect(payload!.format, 'wav');
      expect(_tag(payload.bytes, 0, 4), 'RIFF');
      expect(_tag(payload.bytes, 8, 4), 'WAVE');
      expect(payload.durationSeconds, 3);
      expect(payload.bytes.length, 32000 * 3 + 44);
    });

    test('refuses Opus written before the log recorded frame lengths', () {
      expect(
        captureUploadPayload(
          _segment(framing: CaptureWalFraming.raw),
          Uint8List(64),
        ),
        isNull,
      );
    });

    test('refuses an unknown encoding and an empty payload', () {
      expect(
        captureUploadPayload(_segment(encoding: 'flac'), _framed([20])),
        isNull,
      );
      expect(captureUploadPayload(_segment(), Uint8List(0)), isNull);
    });
  });

  group('the worker transport', () {
    WorkerHttpClient worker(http.Client client) => WorkerHttpClient(
      baseUri: Uri.parse('https://api.example.test'),
      sessionProvider: () async => AuthSession(
        uid: 'user-1',
        idToken: 'firebase-token',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      ),
      client: client,
    );

    test('posts the segment to the idempotent transcription route', () async {
      late http.Request sent;
      final transport = WorkerCaptureUploadTransport(
        worker(
          MockClient((request) async {
            sent = request;
            return http.Response('{"requestId":"r","text":"hi"}', 200);
          }),
        ),
      );

      final segment = _segment(gapBefore: true);
      final result = await transport.upload(segment, _framed([50, 50]));

      expect(result.outcome, CaptureUploadOutcome.accepted);
      expect(sent.method, 'POST');
      expect(sent.url.path, '/api/v1/speech/transcriptions');
      final body = jsonDecode(sent.body) as Map<String, Object?>;
      expect(body['clientMessageId'], segment.id);
      // The endpoint's own id rule, verified against the log's key format.
      expect(RegExp(r'^[A-Za-z0-9._:-]{8,120}$').hasMatch(segment.id), isTrue);
      expect(body['format'], 'ogg');
      expect(body['durationSeconds'], 1);
      expect(body['audioStreamId'], segment.audioStreamId);
      expect(body['gapBefore'], true);
      expect(body['startedAt'], '2026-07-23T09:15:00.000Z');
      // The raw BLE address never leaves the phone.
      expect(body['deviceId'], isNot(contains('AA:BB')));
      expect(base64Decode(body['audio']! as String).length, greaterThan(0));
    });

    test(
      'a retry under the same key replays instead of charging twice',
      () async {
        final keys = <String>[];
        var calls = 0;
        final transport = WorkerCaptureUploadTransport(
          worker(
            MockClient((request) async {
              calls += 1;
              keys.add(
                (jsonDecode(request.body)
                        as Map<String, Object?>)['clientMessageId']!
                    as String,
              );
              return calls == 1
                  ? http.Response('{"text":"hi"}', 200)
                  : http.Response('{"text":"hi","idempotentReplay":true}', 200);
            }),
          ),
        );

        final segment = _segment();
        final first = await transport.upload(segment, _framed([50]));
        final second = await transport.upload(segment, _framed([50]));

        expect(first.outcome, CaptureUploadOutcome.accepted);
        expect(second.outcome, CaptureUploadOutcome.duplicate);
        expect(keys.first, keys.last);
      },
    );

    test('an oversized segment is rejected rather than retried', () async {
      final transport = WorkerCaptureUploadTransport(
        worker(
          MockClient(
            (_) async => http.Response('{"error":"Audio too large"}', 413),
          ),
        ),
      );

      final result = await transport.upload(_segment(), _framed([50]));

      expect(result.outcome, CaptureUploadOutcome.rejected);
      expect(result.message, 'Audio too large');
    });

    test(
      'a segment that cannot be packaged never reaches the network',
      () async {
        var calls = 0;
        final transport = WorkerCaptureUploadTransport(
          worker(
            MockClient((_) async {
              calls += 1;
              return http.Response('{}', 200);
            }),
          ),
        );

        final result = await transport.upload(
          _segment(framing: CaptureWalFraming.raw),
          Uint8List(64),
        );

        expect(result.outcome, CaptureUploadOutcome.rejected);
        expect(calls, 0);
      },
    );

    test('separates the two meanings of 409', () async {
      Future<CaptureUploadResult> respond(String error) =>
          WorkerCaptureUploadTransport(
            worker(
              MockClient(
                (_) async => http.Response(jsonEncode({'error': error}), 409),
              ),
            ),
          ).upload(_segment(), _framed([50]));

      expect(
        (await respond('Speech request in progress')).outcome,
        CaptureUploadOutcome.retry,
      );
      expect(
        (await respond('Client message ID conflict')).outcome,
        CaptureUploadOutcome.rejected,
      );
    });

    test(
      'keeps the audio when the session or entitlement is not there',
      () async {
        for (final status in [401, 403, 429, 503]) {
          final transport = WorkerCaptureUploadTransport(
            worker(
              MockClient((_) async => http.Response('{"error":"no"}', status)),
            ),
          );
          expect(
            (await transport.upload(_segment(), _framed([50]))).outcome,
            CaptureUploadOutcome.retry,
          );
        }
      },
    );
  });
}
