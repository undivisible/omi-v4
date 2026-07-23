import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../native/native_hub.dart';
import 'meeting_notes_screen.dart';

class MeetingAssistPanel extends StatefulWidget {
  const MeetingAssistPanel({required this.services, super.key});

  static const maxHighlights = 3;
  static const maxInsights = 3;
  static const maxContextItems = 3;

  final AppServices services;

  @override
  State<MeetingAssistPanel> createState() => MeetingAssistPanelState();
}

class MeetingAssistPanelState extends State<MeetingAssistPanel> {
  StreamSubscription<NativeEvent>? _events;
  final _jot = TextEditingController();
  final List<String> _highlights = [];
  final List<MeetingInsight> _insights = [];
  final List<String> _memoryContext = [];
  bool _active = false;
  String? _title;
  String? _lastContextRequestId;
  int _contextSequence = 0;

  bool get active => _active;

  @override
  void initState() {
    super.initState();
    _events = widget.services.nativeEvents.listen(_handleEvent);
    _active = widget.services.meetingActive;
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    _jot.dispose();
    super.dispose();
  }

  void _handleEvent(NativeEvent event) {
    if (!mounted) return;
    switch (event) {
      case NativeEventMeetingStateChanged(:final value):
        setState(() {
          _active = value.active;
          _title = value.suggestedTitle ?? _title;
          if (!value.active) {
            _highlights.clear();
            _insights.clear();
            _memoryContext.clear();
          }
        });
      case NativeEventTranscriptDelta(:final value)
          when _active && value.finalSegment && value.text.trim().isNotEmpty:
        setState(() {
          _highlights.add(value.text.trim());
          while (_highlights.length > MeetingAssistPanel.maxHighlights) {
            _highlights.removeAt(0);
          }
        });
      case NativeEventMeetingInsight(:final value) when _active:
        setState(() {
          _insights.add(value);
          while (_insights.length > MeetingAssistPanel.maxInsights) {
            _insights.removeAt(0);
          }
        });
        if (value.kind == 'response') {
          _requestMemoryContext(value.sourceText);
        }
      case NativeEventMemorySearchResults(:final value)
          when _active && value.requestId == _lastContextRequestId:
        setState(() {
          _memoryContext
            ..clear()
            ..addAll(
              value.items
                  .map((item) => item.excerpt.trim())
                  .where((excerpt) => excerpt.isNotEmpty)
                  .take(MeetingAssistPanel.maxContextItems),
            );
        });
      default:
        break;
    }
  }

  void _requestMemoryContext(String query) {
    final requestId = 'meeting-context-${_contextSequence++}';
    _lastContextRequestId = requestId;
    try {
      widget.services.nativeHub.search(
        requestId: requestId,
        query: query,
        limit: MeetingAssistPanel.maxContextItems,
      );
    } on Object {
      _lastContextRequestId = null;
    }
  }

  void _submitJot() {
    final text = _jot.text.trim();
    if (text.isEmpty) return;
    try {
      widget.services.jotMeetingNote(text);
      _jot.clear();
    } on StateError {
      return;
    }
  }

  void _stop() {
    try {
      widget.services.stopMeeting();
    } on StateError {
      return;
    }
  }

  void _openNotes() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => MeetingNotesScreen(services: widget.services),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      label: 'Meeting assistant',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340, maxHeight: 420),
        child: DecoratedBox(
          key: const Key('meeting_assist_panel'),
          decoration: BoxDecoration(
            color: dark ? const Color(0xf0232321) : const Color(0xf0fffefa),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: dark ? const Color(0x1affffff) : const Color(0x1a000000),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.fiber_manual_record,
                      size: 10,
                      color: Color(0xffe4614d),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _title ?? 'Meeting',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('meeting_open_notes'),
                      tooltip: 'Meeting notes',
                      onPressed: _openNotes,
                      icon: const Icon(Icons.sticky_note_2_outlined, size: 17),
                    ),
                    IconButton(
                      key: const Key('meeting_stop'),
                      tooltip: 'End meeting',
                      onPressed: _stop,
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    ),
                  ],
                ),
                if (_highlights.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  for (final highlight in _highlights)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        highlight,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
                for (final insight in _insights) ...[
                  const SizedBox(height: 6),
                  _InsightRow(insight: insight),
                ],
                if (_memoryContext.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'FROM MEMORY',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.1,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  for (final excerpt in _memoryContext)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        excerpt,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 10),
                TextField(
                  key: const Key('meeting_jot_field'),
                  controller: _jot,
                  onSubmitted: (_) => _submitJot(),
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Jot a note — AI expands it later',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({required this.insight});

  final MeetingInsight insight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = switch (insight.kind) {
      'decision' => 'DECISION',
      'action' => 'ACTION',
      _ => 'SUGGESTED ANSWER',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1.1,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          insight.text,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
        ),
      ],
    );
  }
}
