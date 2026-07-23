import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../native/native_hub.dart';

/// Persists the companion home screen's recent final transcript segments so
/// the session list survives app relaunches instead of resetting on every
/// start. Bounded to the most recent [capacity] segments, newest first.
abstract interface class TranscriptLogStore {
  Future<List<TranscriptDelta>> read();
  Future<void> save(List<TranscriptDelta> deltas);
  Future<void> clear();
}

final class PreferencesTranscriptLogStore implements TranscriptLogStore {
  PreferencesTranscriptLogStore({this.capacity = 200});

  static const _key = 'companion_transcripts_v1';

  final int capacity;

  @override
  Future<List<TranscriptDelta>> read() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, Object?>) _fromJson(entry),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> save(List<TranscriptDelta> deltas) async {
    final bounded = deltas.length > capacity
        ? deltas.sublist(0, capacity)
        : deltas;
    await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode([for (final delta in bounded) _toJson(delta)]),
    );
  }

  @override
  Future<void> clear() async {
    await (await SharedPreferences.getInstance()).remove(_key);
  }

  static Map<String, Object?> _toJson(TranscriptDelta delta) => {
    'requestId': delta.requestId,
    'audioStreamId': delta.audioStreamId,
    'segmentId': delta.segmentId,
    'segmentSequence': delta.segmentSequence.toBigInt().toString(),
    'sttEpoch': delta.sttEpoch,
    'deviceId': delta.deviceId,
    'provider': delta.provider,
    'startMs': delta.startMs,
    'endMs': delta.endMs,
    'occurredAtMs': delta.occurredAtMs,
    'text': delta.text,
    'finalSegment': delta.finalSegment,
    'speaker': delta.speaker,
    'channelIndex': delta.channelIndex,
    'language': delta.language,
  };

  static TranscriptDelta _fromJson(Map<String, Object?> json) {
    final requestId = json['requestId'];
    final audioStreamId = json['audioStreamId'];
    final segmentId = json['segmentId'];
    final segmentSequence = json['segmentSequence'];
    final sttEpoch = json['sttEpoch'];
    final deviceId = json['deviceId'];
    final provider = json['provider'];
    final startMs = json['startMs'];
    final endMs = json['endMs'];
    final occurredAtMs = json['occurredAtMs'];
    final text = json['text'];
    final finalSegment = json['finalSegment'];
    final speaker = json['speaker'];
    final channelIndex = json['channelIndex'];
    final language = json['language'];
    if (requestId is! String ||
        audioStreamId is! String ||
        segmentId is! String ||
        segmentSequence is! String ||
        sttEpoch is! int ||
        deviceId is! String ||
        provider is! String ||
        startMs is! int ||
        endMs is! int ||
        occurredAtMs is! int ||
        text is! String ||
        finalSegment is! bool ||
        speaker is! int? ||
        channelIndex is! int? ||
        language is! String?) {
      throw const FormatException('Invalid transcript segment');
    }
    return TranscriptDelta(
      requestId: requestId,
      audioStreamId: audioStreamId,
      segmentId: segmentId,
      segmentSequence: Uint64.fromBigInt(BigInt.parse(segmentSequence)),
      sttEpoch: sttEpoch,
      deviceId: deviceId,
      provider: provider,
      startMs: startMs,
      endMs: endMs,
      occurredAtMs: occurredAtMs,
      text: text,
      finalSegment: finalSegment,
      speaker: speaker,
      channelIndex: channelIndex,
      language: language,
    );
  }
}

final class VolatileTranscriptLogStore implements TranscriptLogStore {
  VolatileTranscriptLogStore({this.capacity = 200});

  final int capacity;
  List<TranscriptDelta> _deltas = const [];

  @override
  Future<List<TranscriptDelta>> read() async => _deltas;

  @override
  Future<void> save(List<TranscriptDelta> deltas) async {
    _deltas = List.unmodifiable(
      deltas.length > capacity ? deltas.sublist(0, capacity) : deltas,
    );
  }

  @override
  Future<void> clear() async => _deltas = const [];
}
