import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../ui/omi_orb.dart';
import '../ui/scroll_edge_fade.dart';
import 'meeting_notes.dart';

class MeetingNotesScreen extends StatefulWidget {
  const MeetingNotesScreen({required this.services, super.key});

  final AppServices services;

  @override
  State<MeetingNotesScreen> createState() => _MeetingNotesScreenState();
}

class _MeetingNotesScreenState extends State<MeetingNotesScreen> {
  List<MeetingNote>? _notes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final notes = await widget.services.meetingNotes.list();
      if (!mounted) return;
      setState(() => _notes = notes);
    } on Object {
      if (!mounted) return;
      setState(() => _error = 'Could not load meeting notes.');
    }
  }

  Future<void> _remove(MeetingNote note) async {
    await widget.services.meetingNotes.remove(note.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final notes = _notes;
    return _MeetingNotesShell(
      title: 'Meeting notes',
      body: switch ((notes, _error)) {
        (_, final String error) => Center(child: Text(error)),
        (null, _) => const Center(child: OmiActivityOrb.loading(size: 44)),
        (final List<MeetingNote> loaded, _) when loaded.isEmpty => const Center(
          child: Text('No meeting notes yet.'),
        ),
        (final List<MeetingNote> loaded, _) => ScrollEdgeFade(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            itemCount: loaded.length,
            separatorBuilder: (_, _) => const SizedBox(height: 0),
            itemBuilder: (context, index) {
              final note = loaded[index];
              final colors = _MeetingNotesColors.of(context);
              return DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.hairline)),
                ),
                child: ListTile(
                  key: Key('meeting_note_${note.id}'),
                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                  title: Text(
                    note.title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: colors.ink,
                    ),
                  ),
                  subtitle: Text(
                    note.summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.muted),
                  ),
                  trailing: IconButton(
                    key: Key('meeting_note_delete_${note.id}'),
                    tooltip: 'Delete note',
                    icon: Icon(Icons.delete_outline, size: 18, color: colors.muted),
                    onPressed: () => _remove(note),
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => MeetingNoteDetailScreen(note: note),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      },
    );
  }
}

class MeetingNoteDetailScreen extends StatelessWidget {
  const MeetingNoteDetailScreen({required this.note, super.key});

  final MeetingNote note;

  @override
  Widget build(BuildContext context) => _MeetingNotesShell(
    title: note.title,
    trailing: IconButton(
      key: const Key('meeting_note_copy'),
      tooltip: 'Copy as markdown',
      icon: Icon(Icons.copy_outlined, size: 18, color: _MeetingNotesColors.of(context).muted),
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: note.markdown));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copied note as markdown.')),
        );
      },
    ),
    body: ScrollEdgeFade(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: SelectableText(
          note.markdown,
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: _MeetingNotesColors.of(context).ink,
          ),
        ),
      ),
    ),
  );
}

class _MeetingNotesColors {
  const _MeetingNotesColors._({
    required this.ink,
    required this.muted,
    required this.hairline,
    required this.surface,
  });

  final Color ink;
  final Color muted;
  final Color hairline;
  final Color surface;

  static _MeetingNotesColors of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? const _MeetingNotesColors._(
            ink: Color(0xfff4f2ea),
            muted: Color(0xffa6a49c),
            hairline: Color(0x1affffff),
            surface: Color(0xff1c1c1a),
          )
        : const _MeetingNotesColors._(
            ink: Color(0xff171716),
            muted: Color(0xff706e68),
            hairline: Color(0x1a000000),
            surface: Color(0xfff7f6f1),
          );
  }
}

class _MeetingNotesShell extends StatelessWidget {
  const _MeetingNotesShell({
    required this.title,
    required this.body,
    this.trailing,
  });

  final String title;
  final Widget body;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = _MeetingNotesColors.of(context);
    return Scaffold(
      backgroundColor: colors.surface,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('meeting_notes_close'),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(Icons.close_rounded, color: colors.ink),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.ink,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
