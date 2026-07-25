import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../native/native_hub.dart' show MeetingCompleted;

class MeetingNote {
  static const maxRawTranscriptCharacters = 48000;

  MeetingNote({
    required this.id,
    required this.title,
    required this.summary,
    required String meetingType,
    required String rawTranscript,
    required this.startedAt,
    required this.endedAt,
    required List<String> participants,
    required List<String> keyPoints,
    required List<String> decisions,
    required List<String> actions,
    required this.markdown,
    required this.metadataJson,
    this.starred = false,
    Set<int> completedActionIndexes = const {},
  }) : meetingType = _meetingType(meetingType),
       rawTranscript = _boundedTranscript(rawTranscript),
       participants = List.unmodifiable(participants),
       keyPoints = List.unmodifiable(keyPoints),
       decisions = List.unmodifiable(decisions),
       actions = List.unmodifiable(actions),
       completedActionIndexes = Set.unmodifiable(
         completedActionIndexes.where(
           (index) => index >= 0 && index < actions.length,
         ),
       );

  factory MeetingNote.fromCompleted(MeetingCompleted completed) => MeetingNote(
    id: 'meeting-${completed.endedAtMs}',
    title: completed.title,
    summary: completed.summary,
    meetingType: completed.meetingType,
    rawTranscript: completed.rawTranscript,
    startedAt: DateTime.fromMillisecondsSinceEpoch(
      completed.startedAtMs,
      isUtc: true,
    ),
    endedAt: DateTime.fromMillisecondsSinceEpoch(
      completed.endedAtMs,
      isUtc: true,
    ),
    participants: completed.participants,
    keyPoints: completed.keyPoints,
    decisions: completed.decisions,
    actions: completed.actions,
    markdown: completed.noteMarkdown,
    metadataJson: completed.metadataJson,
  );

  factory MeetingNote.fromJson(Map<String, Object?> json) => MeetingNote(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? 'Meeting',
    summary: json['summary'] as String? ?? '',
    meetingType: json['meetingType'] as String? ?? 'general',
    rawTranscript: json['rawTranscript'] as String? ?? '',
    startedAt:
        DateTime.tryParse(json['startedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    endedAt:
        DateTime.tryParse(json['endedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    participants: _stringList(json['participants']),
    keyPoints: _stringList(json['keyPoints']),
    decisions: _stringList(json['decisions']),
    actions: _stringList(json['actions']),
    markdown: json['markdown'] as String? ?? '',
    metadataJson: json['metadataJson'] as String? ?? '',
    starred: json['starred'] is bool ? json['starred'] as bool : false,
    completedActionIndexes: _intSet(json['completedActionIndexes']),
  );

  final String id;
  final String title;
  final String summary;
  final String meetingType;
  final String rawTranscript;
  final DateTime startedAt;
  final DateTime endedAt;
  final List<String> participants;
  final List<String> keyPoints;
  final List<String> decisions;
  final List<String> actions;
  final String markdown;
  final String metadataJson;
  final bool starred;
  final Set<int> completedActionIndexes;

  String get meetingTypeLabel => switch (meetingType) {
    'one-on-one' => 'One-on-one',
    'customer-interview' => 'Customer interview',
    'project-planning' => 'Project planning',
    'standup' => 'Standup',
    'sales' => 'Sales',
    'retrospective' => 'Retrospective',
    _ => 'General',
  };

  MeetingNote copyWith({bool? starred, Set<int>? completedActionIndexes}) =>
      MeetingNote(
        id: id,
        title: title,
        summary: summary,
        meetingType: meetingType,
        rawTranscript: rawTranscript,
        startedAt: startedAt,
        endedAt: endedAt,
        participants: participants,
        keyPoints: keyPoints,
        decisions: decisions,
        actions: actions,
        markdown: markdown,
        metadataJson: metadataJson,
        starred: starred ?? this.starred,
        completedActionIndexes:
            completedActionIndexes ?? this.completedActionIndexes,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'summary': summary,
    'meetingType': meetingType,
    'rawTranscript': rawTranscript,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt.toUtc().toIso8601String(),
    'participants': participants,
    'keyPoints': keyPoints,
    'decisions': decisions,
    'actions': actions,
    'markdown': markdown,
    'metadataJson': metadataJson,
    'starred': starred,
    'completedActionIndexes': completedActionIndexes.toList()..sort(),
  };
}

String _meetingType(String value) =>
    const {
      'general',
      'one-on-one',
      'standup',
      'sales',
      'customer-interview',
      'retrospective',
      'project-planning',
    }.contains(value)
    ? value
    : 'general';

String _boundedTranscript(String value) {
  final runes = value.runes;
  return runes.length > MeetingNote.maxRawTranscriptCharacters
      ? String.fromCharCodes(runes.take(MeetingNote.maxRawTranscriptCharacters))
      : value;
}

List<String> _stringList(Object? value) =>
    value is List ? List.unmodifiable(value.whereType<String>()) : const [];

Set<int> _intSet(Object? value) =>
    value is List ? Set.unmodifiable(value.whereType<int>()) : const {};

abstract interface class MeetingNotesStore {
  Future<List<MeetingNote>> list();
  Future<void> save(MeetingNote note);
  Future<void> remove(String id);
}

final class PreferencesMeetingNotesStore implements MeetingNotesStore {
  static const _key = 'meetingNotes';
  static const maxNotes = 100;

  @override
  Future<List<MeetingNote>> list() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, Object?>>()
          .map(MeetingNote.fromJson)
          .toList();
    } on FormatException {
      return const [];
    }
  }

  @override
  Future<void> save(MeetingNote note) async {
    final notes = [
      note,
      ...(await list()).where((existing) => existing.id != note.id),
    ].take(maxNotes).toList();
    await _write(notes);
  }

  @override
  Future<void> remove(String id) async =>
      _write((await list()).where((note) => note.id != id).toList());

  Future<void> _write(List<MeetingNote> notes) async {
    final saved = await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode([for (final note in notes) note.toJson()]),
    );
    if (!saved) {
      throw StateError('Could not save meeting notes.');
    }
  }
}

final class VolatileMeetingNotesStore implements MeetingNotesStore {
  final List<MeetingNote> notes = [];

  @override
  Future<List<MeetingNote>> list() async => List.unmodifiable(notes);

  @override
  Future<void> save(MeetingNote note) async {
    notes.removeWhere((existing) => existing.id == note.id);
    notes.insert(0, note);
  }

  @override
  Future<void> remove(String id) async =>
      notes.removeWhere((note) => note.id == id);
}
