import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('Meeting notes')),
      body: switch ((notes, _error)) {
        (_, final String error) => Center(child: Text(error)),
        (null, _) => const Center(child: CircularProgressIndicator()),
        (final List<MeetingNote> loaded, _) when loaded.isEmpty => const Center(
          child: Text('No meeting notes yet.'),
        ),
        (final List<MeetingNote> loaded, _) => ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: loaded.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final note = loaded[index];
            return ListTile(
              key: Key('meeting_note_${note.id}'),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              tileColor: Theme.of(context).colorScheme.surface,
              title: Text(note.title),
              subtitle: Text(
                note.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                key: Key('meeting_note_delete_${note.id}'),
                tooltip: 'Delete note',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => _remove(note),
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => MeetingNoteDetailScreen(note: note),
                ),
              ),
            );
          },
        ),
      },
    );
  }
}

class MeetingNoteDetailScreen extends StatelessWidget {
  const MeetingNoteDetailScreen({required this.note, super.key});

  final MeetingNote note;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(note.title),
      actions: [
        IconButton(
          key: const Key('meeting_note_copy'),
          tooltip: 'Copy as markdown',
          icon: const Icon(Icons.copy_outlined, size: 18),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: note.markdown));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Copied note as markdown.')),
            );
          },
        ),
      ],
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: SelectableText(
        note.markdown,
        style: const TextStyle(fontSize: 13.5, height: 1.5),
      ),
    ),
  );
}
