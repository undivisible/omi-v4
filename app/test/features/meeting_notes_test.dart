import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/meeting_notes.dart';
import 'package:omi/native/native_hub.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const completed = MeetingCompleted(
    title: 'Standup',
    summary: 'Team agreed to ship Friday.',
    actions: ['Email release notes'],
    startedAtMs: 5000,
    endedAtMs: 65000,
    participants: ['Ana'],
    keyPoints: ['Friday is the date'],
    decisions: ['Ship Friday'],
    noteMarkdown: '# Standup\n\n- [ ] Email release notes\n',
    metadataJson: '{"kind":"meeting"}',
  );

  test('notes are built from completed meetings and round-trip json', () {
    final note = MeetingNote.fromCompleted(completed);
    expect(note.id, 'meeting-65000');
    expect(note.title, 'Standup');
    expect(
      note.startedAt,
      DateTime.fromMillisecondsSinceEpoch(5000, isUtc: true),
    );
    expect(
      note.endedAt,
      DateTime.fromMillisecondsSinceEpoch(65000, isUtc: true),
    );
    expect(note.participants, ['Ana']);
    expect(note.keyPoints, ['Friday is the date']);
    expect(note.decisions, ['Ship Friday']);
    expect(note.actions, ['Email release notes']);
    expect(note.markdown, contains('# Standup'));

    final restored = MeetingNote.fromJson(note.toJson());
    expect(restored.id, note.id);
    expect(restored.title, note.title);
    expect(restored.summary, note.summary);
    expect(restored.startedAt, note.startedAt);
    expect(restored.endedAt, note.endedAt);
    expect(restored.participants, note.participants);
    expect(restored.keyPoints, note.keyPoints);
    expect(restored.decisions, note.decisions);
    expect(restored.actions, note.actions);
    expect(restored.markdown, note.markdown);
    expect(restored.metadataJson, note.metadataJson);
  });

  test('malformed persisted json degrades to defaults', () {
    final note = MeetingNote.fromJson(const {
      'participants': ['Ana', 7],
      'startedAt': 'not-a-date',
    });
    expect(note.title, 'Meeting');
    expect(note.participants, ['Ana']);
    expect(note.startedAt, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
  });

  test('preferences store saves newest-first, dedupes, and removes', () async {
    SharedPreferences.setMockInitialValues(const {});
    final store = PreferencesMeetingNotesStore();
    expect(await store.list(), isEmpty);

    final first = MeetingNote.fromCompleted(completed);
    final second = MeetingNote.fromCompleted(
      completed.copyWith(endedAtMs: 99000, title: 'Retro'),
    );
    await store.save(first);
    await store.save(second);
    await store.save(second);

    final listed = await store.list();
    expect(listed.map((note) => note.title).toList(), ['Retro', 'Standup']);

    await store.remove(first.id);
    expect((await store.list()).map((note) => note.id), ['meeting-99000']);
  });

  test('preferences store survives corrupted persisted data', () async {
    SharedPreferences.setMockInitialValues(const {'meetingNotes': '{oops'});
    expect(await PreferencesMeetingNotesStore().list(), isEmpty);
  });

  test('volatile store mirrors the interface', () async {
    final store = VolatileMeetingNotesStore();
    final note = MeetingNote.fromCompleted(completed);
    await store.save(note);
    expect((await store.list()).single.id, note.id);
    await store.remove(note.id);
    expect(await store.list(), isEmpty);
  });
}
