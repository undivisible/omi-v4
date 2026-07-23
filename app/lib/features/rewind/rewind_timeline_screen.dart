import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../ui/omi_typography.dart';
import 'rewind_models.dart';
import 'rewind_service.dart';
import 'rewind_settings_tile.dart' show RewindColors;

/// A deliberately plain timeline: newest first, searchable over the text that
/// was recognized on-device, with a per-frame delete. The capture policy and
/// the privacy controls are the substance of Rewind; this is the window onto
/// what they produced.
class RewindTimelineScreen extends StatefulWidget {
  const RewindTimelineScreen({required this.service, super.key});

  final RewindService service;

  @override
  State<RewindTimelineScreen> createState() => _RewindTimelineScreenState();
}

class _RewindTimelineScreenState extends State<RewindTimelineScreen> {
  final _query = TextEditingController();
  String _search = '';
  RewindFrame? _selected;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.service.removeListener(_onChanged);
    _query.dispose();
    super.dispose();
  }

  List<RewindFrame> get _visible {
    if (_search.trim().isEmpty) {
      return widget.service.frames.reversed.toList(growable: false);
    }
    return widget.service.search(_search);
  }

  @override
  Widget build(BuildContext context) {
    final colors = RewindColors.of(context);
    final frames = _visible;
    final selected = _selected;
    return Scaffold(
      backgroundColor: colors.page,
      appBar: AppBar(
        backgroundColor: colors.page,
        elevation: 0,
        title: Text(
          'Rewind',
          style: TextStyle(
            fontFamily: OmiFonts.sans,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: colors.ink,
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              key: const Key('rewind_search'),
              controller: _query,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded, size: 18),
                hintText: 'Search what was on screen',
              ),
              onChanged: (value) => setState(() => _search = value),
            ),
          ),
          Expanded(
            child: frames.isEmpty
                ? Center(
                    child: Text(
                      _search.trim().isEmpty
                          ? 'Nothing recorded yet.'
                          : 'No frames match that.',
                      style: TextStyle(
                        fontFamily: OmiFonts.sans,
                        fontSize: 13,
                        color: colors.muted,
                      ),
                    ),
                  )
                : Row(
                    children: [
                      SizedBox(
                        width: 320,
                        child: ListView.builder(
                          itemCount: frames.length,
                          itemBuilder: (context, index) => _FrameRow(
                            colors: colors,
                            frame: frames[index],
                            selected: identical(frames[index], selected),
                            onTap: () =>
                                setState(() => _selected = frames[index]),
                          ),
                        ),
                      ),
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: colors.hairline,
                      ),
                      Expanded(
                        child: selected == null
                            ? Center(
                                child: Text(
                                  'Pick a moment.',
                                  style: TextStyle(
                                    fontFamily: OmiFonts.sans,
                                    fontSize: 13,
                                    color: colors.muted,
                                  ),
                                ),
                              )
                            : _FrameDetail(
                                colors: colors,
                                frame: selected,
                                file: widget.service.store.fileFor(selected),
                                onDelete: () {
                                  unawaited(widget.service.delete(selected));
                                  setState(() => _selected = null);
                                },
                              ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _FrameRow extends StatelessWidget {
  const _FrameRow({
    required this.colors,
    required this.frame,
    required this.selected,
    required this.onTap,
  });

  final RewindColors colors;
  final RewindFrame frame;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final at = frame.capturedAt;
    final time =
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Container(
          color: selected ? colors.panel : null,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                time,
                style: TextStyle(
                  fontFamily: OmiFonts.mono,
                  fontSize: 12,
                  color: colors.muted,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  frame.windowTitle ?? frame.appName ?? 'Screen',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: OmiFonts.sans,
                    fontSize: 12,
                    color: colors.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FrameDetail extends StatelessWidget {
  const _FrameDetail({
    required this.colors,
    required this.frame,
    required this.file,
    required this.onDelete,
  });

  final RewindColors colors;
  final RewindFrame frame;
  final File file;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${frame.appName ?? 'Screen'} · '
                '${frame.capturedAt.toLocal()}',
                style: TextStyle(
                  fontFamily: OmiFonts.sans,
                  fontSize: 12,
                  color: colors.muted,
                ),
              ),
            ),
            TextButton(
              key: const Key('rewind_delete_frame'),
              onPressed: onDelete,
              child: const Text('Delete'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              file,
              fit: BoxFit.contain,
              alignment: Alignment.topLeft,
              errorBuilder: (context, _, _) => Text(
                'That frame is no longer on disk.',
                style: TextStyle(
                  fontFamily: OmiFonts.sans,
                  fontSize: 12,
                  color: colors.muted,
                ),
              ),
            ),
          ),
        ),
        if (frame.ocrText != null) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 120,
            child: SingleChildScrollView(
              child: SelectableText(
                frame.ocrText!,
                style: TextStyle(
                  fontFamily: OmiFonts.mono,
                  fontSize: 11,
                  height: 1.4,
                  color: colors.muted,
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
