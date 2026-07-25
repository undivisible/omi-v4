import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/meeting_notes.dart';
import 'package:omi/features/meeting_notes_screen.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  final planning = MeetingNote(
    id: 'planning',
    title: 'Launch plan',
    summary: 'Pick the launch date',
    meetingType: 'project-planning',
    rawTranscript: 'Rae: Customers need the migration guide.',
    startedAt: DateTime.utc(2026, 7, 25, 14),
    endedAt: DateTime.utc(2026, 7, 25, 14, 30),
    participants: const ['Rae'],
    keyPoints: const ['Migration guide'],
    decisions: const ['Launch Tuesday'],
    actions: const ['Write the guide', 'Email customers'],
    markdown: '# Launch plan\n\nShip Tuesday.',
    metadataJson: '',
  );
  final standup = MeetingNote(
    id: 'standup',
    title: 'Daily sync',
    summary: 'Unblocked the release',
    meetingType: 'standup',
    rawTranscript: '',
    startedAt: DateTime.utc(2026, 7, 24, 14),
    endedAt: DateTime.utc(2026, 7, 24, 14, 15),
    participants: const [],
    keyPoints: const [],
    decisions: const [],
    actions: const [],
    markdown: '# Daily sync',
    metadataJson: '',
  );

  testWidgets('searches notes, groups by inferred type, and persists stars', (
    tester,
  ) async {
    final store = VolatileMeetingNotesStore()
      ..notes.addAll([planning, standup]);
    final services = _services()..meetingNotes = store;
    addTearDown(services.dispose);

    await tester.pumpWidget(
      MaterialApp(home: MeetingNotesScreen(services: services)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('meeting_type_group_project-planning')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('meeting_type_group_standup')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('meeting_notes_search')),
      'migration guide',
    );
    await tester.pump();
    expect(find.text('Launch plan'), findsOneWidget);
    expect(find.text('Daily sync'), findsNothing);

    await tester.tap(find.byKey(const Key('meeting_notes_search_clear')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('meeting_note_star_planning')));
    await tester.pumpAndSettle();
    expect(
      (await store.list()).firstWhere((note) => note.id == 'planning').starred,
      isTrue,
    );
  });

  testWidgets('detail persists actions and shares each note representation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1800);
    addTearDown(tester.view.reset);
    final store = VolatileMeetingNotesStore()..notes.add(planning);
    final shared = <({String subject, String text})>[];

    await tester.pumpWidget(
      MaterialApp(
        home: MeetingNoteDetailScreen(
          note: planning,
          store: store,
          share: ({required subject, required text}) async {
            shared.add((subject: subject, text: text));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> reveal(Finder finder) async {
      for (
        var attempt = 0;
        attempt < 12 && finder.evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(find.byType(ListView), const Offset(0, -220));
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
    }

    expect(find.text('Project planning'), findsOneWidget);
    await reveal(find.textContaining('Launch Tuesday'));
    expect(find.textContaining('Launch Tuesday'), findsOneWidget);
    await reveal(find.byKey(const Key('meeting_action_0')));
    await tester.tap(find.byKey(const Key('meeting_action_0')));
    await tester.pumpAndSettle();
    expect((await store.list()).single.completedActionIndexes, {0});

    for (final key in [
      const Key('meeting_note_share_summary'),
      const Key('meeting_note_share_transcript'),
      const Key('meeting_note_share_full'),
    ]) {
      await reveal(find.byKey(key));
      await tester.tap(find.byKey(key));
      await tester.pump();
    }
    expect(shared.map((item) => item.text), [
      planning.summary,
      planning.rawTranscript,
      planning.markdown,
    ]);

    await reveal(find.byKey(const Key('meeting_note_transcript')));
    await tester.tap(find.byKey(const Key('meeting_note_transcript')));
    await tester.pumpAndSettle();
    expect(find.text(planning.rawTranscript), findsOneWidget);
  });
}

AppServices _services() => AppServices.forTesting(
  nativeHub: const UnavailableNativeHub('test'),
  deviceRelay: DeviceRelayService(
    role: DeviceRelayRole.desktopObserver,
    adapter: const UnavailableDeviceRelayAdapter(),
  ),
  auth: AuthController(const UnconfiguredAuthGateway()),
  memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
);
