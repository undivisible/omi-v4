import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

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
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final notes = await widget.services.meetingNotes.list();
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _error = null;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _error = 'Could not load meeting notes.');
    }
  }

  Future<void> _remove(MeetingNote note) async {
    await widget.services.meetingNotes.remove(note.id);
    await _load();
  }

  Future<void> _toggleStar(MeetingNote note) async {
    try {
      await widget.services.meetingNotes.save(
        note.copyWith(starred: !note.starred),
      );
      await _load();
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not update note.')));
    }
  }

  List<MeetingNote> _matchingNotes(List<MeetingNote> notes) {
    final query = _search.text.trim().toLowerCase();
    final matches = query.isEmpty
        ? notes
        : notes.where((note) {
            final searchable = [
              note.title,
              note.summary,
              note.meetingTypeLabel,
              ...note.participants,
              ...note.keyPoints,
              ...note.decisions,
              ...note.actions,
              note.rawTranscript,
            ].join('\n').toLowerCase();
            return searchable.contains(query);
          });
    return matches.toList()..sort((left, right) {
      if (left.starred != right.starred) return left.starred ? -1 : 1;
      return right.endedAt.compareTo(left.endedAt);
    });
  }

  Widget _loadedBody(List<MeetingNote> notes) {
    final visible = _matchingNotes(notes);
    final grouped = <String, List<MeetingNote>>{};
    for (final note in visible) {
      grouped.putIfAbsent(note.meetingType, () => []).add(note);
    }
    final colors = _MeetingNotesColors.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: TextField(
            key: const Key('meeting_notes_search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search meeting notes',
              prefixIcon: const Icon(Icons.search_rounded, size: 19),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      key: const Key('meeting_notes_search_clear'),
                      tooltip: 'Clear search',
                      onPressed: () {
                        _search.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
              filled: true,
              fillColor: colors.ink.withValues(alpha: 0.04),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('No matching meeting notes.'))
              : ScrollEdgeFade(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    children: [
                      for (final entry in grouped.entries) ...[
                        Padding(
                          key: Key('meeting_type_group_${entry.key}'),
                          padding: const EdgeInsets.fromLTRB(0, 12, 0, 7),
                          child: Text(
                            entry.value.first.meetingTypeLabel.toUpperCase(),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                              color: colors.muted,
                            ),
                          ),
                        ),
                        for (final note in entry.value)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(color: colors.hairline),
                              ),
                            ),
                            child: ListTile(
                              key: Key('meeting_note_${note.id}'),
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 4,
                              ),
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
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    key: Key('meeting_note_star_${note.id}'),
                                    tooltip: note.starred
                                        ? 'Unstar note'
                                        : 'Star note',
                                    icon: Icon(
                                      note.starred
                                          ? Icons.star_rounded
                                          : Icons.star_border_rounded,
                                      size: 19,
                                      color: note.starred
                                          ? const Color(0xffd99718)
                                          : colors.muted,
                                    ),
                                    onPressed: () => _toggleStar(note),
                                  ),
                                  IconButton(
                                    key: Key('meeting_note_delete_${note.id}'),
                                    tooltip: 'Delete note',
                                    icon: Icon(
                                      Icons.delete_outline,
                                      size: 18,
                                      color: colors.muted,
                                    ),
                                    onPressed: () => _remove(note),
                                  ),
                                ],
                              ),
                              onTap: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (context) =>
                                        MeetingNoteDetailScreen(
                                          note: note,
                                          store: widget.services.meetingNotes,
                                        ),
                                  ),
                                );
                                await _load();
                              },
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final notes = _notes;
    return _MeetingNotesShell(
      title: 'Meeting notes',
      body: switch ((notes, _error)) {
        (_, final String error) => Center(child: Text(error)),
        // A full-screen wait with room to breathe: the diagonals drop to an
        // inner ring and counter-turn, so the mark reads as nested circles
        // rather than the tight loading pulse a button-sized mark gets.
        (null, _) => const Center(
          child: OmiActivityOrb(
            size: 44,
            motion: OmiOrbMotion.doubleCircle,
            period: Duration(milliseconds: 2400),
          ),
        ),
        (final List<MeetingNote> loaded, _) when loaded.isEmpty => const Center(
          child: Text('No meeting notes yet.'),
        ),
        (final List<MeetingNote> loaded, _) => _loadedBody(loaded),
      },
    );
  }
}

typedef MeetingNoteShare =
    Future<void> Function({required String subject, required String text});

class MeetingNoteDetailScreen extends StatefulWidget {
  const MeetingNoteDetailScreen({
    required this.note,
    required this.store,
    this.share,
    super.key,
  });

  final MeetingNote note;
  final MeetingNotesStore store;
  final MeetingNoteShare? share;

  @override
  State<MeetingNoteDetailScreen> createState() =>
      _MeetingNoteDetailScreenState();
}

class _MeetingNoteDetailScreenState extends State<MeetingNoteDetailScreen> {
  late MeetingNote _note = widget.note;

  String get _fullNote {
    if (_note.markdown.trim().isNotEmpty) return _note.markdown;
    return [
      '# ${_note.title}',
      if (_note.summary.isNotEmpty) '\n${_note.summary}',
      if (_note.decisions.isNotEmpty) ...[
        '\n## Decisions',
        for (final decision in _note.decisions) '- $decision',
      ],
      if (_note.actions.isNotEmpty) ...[
        '\n## Actions',
        for (var index = 0; index < _note.actions.length; index++)
          '- [${_note.completedActionIndexes.contains(index) ? 'x' : ' '}] '
              '${_note.actions[index]}',
      ],
      if (_note.rawTranscript.isNotEmpty) ...[
        '\n## Transcript',
        _note.rawTranscript,
      ],
    ].join('\n');
  }

  Future<void> _persist(MeetingNote updated) async {
    final previous = _note;
    setState(() => _note = updated);
    try {
      await widget.store.save(updated);
    } on Object {
      if (!mounted) return;
      setState(() => _note = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not update note.')));
    }
  }

  Future<void> _share(
    BuildContext originContext, {
    required String subject,
    required String text,
  }) async {
    try {
      final share = widget.share;
      if (share != null) {
        await share(subject: subject, text: text);
        return;
      }
      final renderBox = originContext.findRenderObject();
      await SharePlus.instance.share(
        ShareParams(
          subject: subject,
          text: text,
          sharePositionOrigin: renderBox is RenderBox
              ? renderBox.localToGlobal(Offset.zero) & renderBox.size
              : null,
        ),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not share note.')));
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _fullNote));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied note as markdown.')));
  }

  @override
  Widget build(BuildContext context) => _MeetingNotesShell(
    title: _note.title,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('meeting_note_detail_star'),
          tooltip: _note.starred ? 'Unstar note' : 'Star note',
          onPressed: () => _persist(_note.copyWith(starred: !_note.starred)),
          icon: Icon(
            _note.starred ? Icons.star_rounded : Icons.star_border_rounded,
            size: 19,
            color: _note.starred
                ? const Color(0xffd99718)
                : _MeetingNotesColors.of(context).muted,
          ),
        ),
        IconButton(
          key: const Key('meeting_note_copy'),
          tooltip: 'Copy as markdown',
          icon: Icon(
            Icons.copy_outlined,
            size: 18,
            color: _MeetingNotesColors.of(context).muted,
          ),
          onPressed: _copy,
        ),
      ],
    ),
    body: ScrollEdgeFade(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Chip(
                key: const Key('meeting_note_type'),
                avatar: const Icon(Icons.auto_awesome_rounded, size: 15),
                label: Text(_note.meetingTypeLabel),
              ),
              Text(
                _meetingTime(_note),
                style: TextStyle(
                  fontSize: 12,
                  color: _MeetingNotesColors.of(context).muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _MeetingNoteSection(
            title: 'Summary',
            child: SelectableText(
              _note.summary.isEmpty ? 'No summary recorded.' : _note.summary,
            ),
          ),
          _MeetingNoteListSection(
            title: 'Decisions',
            emptyText: 'No decisions recorded.',
            values: _note.decisions,
          ),
          _MeetingNoteSection(
            title: 'Actions',
            child: _note.actions.isEmpty
                ? const Text('No actions recorded.')
                : Column(
                    children: [
                      for (var index = 0; index < _note.actions.length; index++)
                        CheckboxListTile(
                          key: Key('meeting_action_$index'),
                          value: _note.completedActionIndexes.contains(index),
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            _note.actions[index],
                            style: TextStyle(
                              decoration:
                                  _note.completedActionIndexes.contains(index)
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          onChanged: (checked) {
                            final completed = {..._note.completedActionIndexes};
                            if (checked ?? false) {
                              completed.add(index);
                            } else {
                              completed.remove(index);
                            }
                            _persist(
                              _note.copyWith(completedActionIndexes: completed),
                            );
                          },
                        ),
                    ],
                  ),
          ),
          _MeetingNoteListSection(
            title: 'Key points',
            emptyText: 'No key points recorded.',
            values: _note.keyPoints,
          ),
          _MeetingNoteSection(
            title: 'Share',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Builder(
                  builder: (context) => OutlinedButton.icon(
                    key: const Key('meeting_note_share_summary'),
                    onPressed: _note.summary.trim().isEmpty
                        ? null
                        : () => _share(
                            context,
                            subject: '${_note.title} summary',
                            text: _note.summary,
                          ),
                    icon: const Icon(Icons.ios_share_rounded, size: 16),
                    label: const Text('Summary'),
                  ),
                ),
                Builder(
                  builder: (context) => OutlinedButton.icon(
                    key: const Key('meeting_note_share_transcript'),
                    onPressed: _note.rawTranscript.trim().isEmpty
                        ? null
                        : () => _share(
                            context,
                            subject: '${_note.title} transcript',
                            text: _note.rawTranscript,
                          ),
                    icon: const Icon(Icons.ios_share_rounded, size: 16),
                    label: const Text('Transcript'),
                  ),
                ),
                Builder(
                  builder: (context) => OutlinedButton.icon(
                    key: const Key('meeting_note_share_full'),
                    onPressed: () =>
                        _share(context, subject: _note.title, text: _fullNote),
                    icon: const Icon(Icons.ios_share_rounded, size: 16),
                    label: const Text('Full note'),
                  ),
                ),
              ],
            ),
          ),
          _MeetingNoteExpansion(
            key: const Key('meeting_note_transcript'),
            title: 'Transcript',
            child: SelectableText(
              _note.rawTranscript.isEmpty
                  ? 'Transcript unavailable.'
                  : _note.rawTranscript,
            ),
          ),
          _MeetingNoteExpansion(
            key: const Key('meeting_note_full_note'),
            title: 'Full note',
            child: SelectableText(_fullNote),
          ),
        ],
      ),
    ),
  );
}

class _MeetingNoteSection extends StatelessWidget {
  const _MeetingNoteSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = _MeetingNotesColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: colors.ink,
              ),
            ),
          ),
          const SizedBox(height: 8),
          DefaultTextStyle(
            style: TextStyle(fontSize: 13.5, height: 1.5, color: colors.ink),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _MeetingNoteListSection extends StatelessWidget {
  const _MeetingNoteListSection({
    required this.title,
    required this.emptyText,
    required this.values,
  });

  final String title;
  final String emptyText;
  final List<String> values;

  @override
  Widget build(BuildContext context) => _MeetingNoteSection(
    title: title,
    child: values.isEmpty
        ? Text(emptyText)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final value in values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text('• $value'),
                ),
            ],
          ),
  );
}

class _MeetingNoteExpansion extends StatelessWidget {
  const _MeetingNoteExpansion({
    required this.title,
    required this.child,
    super.key,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 20),
    title: Semantics(
      header: true,
      child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    ),
    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
    children: [child],
  );
}

String _meetingTime(MeetingNote note) {
  final start = note.startedAt.toLocal();
  final minutes = note.endedAt.difference(note.startedAt).inMinutes;
  final hour = start.hour == 0
      ? 12
      : start.hour > 12
      ? start.hour - 12
      : start.hour;
  final minute = start.minute.toString().padLeft(2, '0');
  final period = start.hour >= 12 ? 'PM' : 'AM';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[start.month - 1]} ${start.day} · '
      '$hour:$minute $period · $minutes min';
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
