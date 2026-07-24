import 'dart:async';

import 'package:crepuscularity_flutter/crepuscularity_flutter.dart';
import 'package:flutter/material.dart';

import '../currents/crepus_current.dart';
import 'markdown_text.dart';

/// One ordered piece of an assistant message: either a run of markdown prose or
/// a fenced `crepus` artifact block. Splitting the raw text into segments lets
/// prose render exactly as it does today while an interleaved artifact draws as
/// an interactive surface.
class _Segment {
  const _Segment.markdown(this.text) : isArtifact = false;
  const _Segment.artifact(this.text) : isArtifact = true;

  final String text;
  final bool isArtifact;
}

/// Splits assistant `text` on fenced blocks whose info-string is exactly
/// `crepus` (```crepus\n<source>\n```) and renders each segment:
///   * markdown → the existing [AssistantMarkdown] (byte-identical behaviour),
///   * a valid crepus block → an artifact card drawing [CrepusView.fromSource],
///   * an invalid crepus block → the raw fenced block back through
///     [AssistantMarkdown] as a plain code segment (graceful fallback).
///
/// A message with no ```crepus fence renders as a single markdown segment, so
/// today's output is preserved exactly.
class AssistantContent extends StatelessWidget {
  const AssistantContent(
    this.text, {
    required this.onPrompt,
    required this.onDraftPrompt,
    required this.palette,
    super.key,
  });

  final String text;
  final ValueChanged<String> onPrompt;
  final ValueChanged<String> onDraftPrompt;
  final CrepusCurrentPalette palette;

  @override
  Widget build(BuildContext context) {
    final segments = _splitSegments(text);
    // No artifact fence → render exactly as before: a single markdown widget.
    if (segments.length == 1 && !segments.first.isArtifact) {
      return AssistantMarkdown(segments.first.text);
    }
    final children = <Widget>[];
    for (final segment in segments) {
      if (!segment.isArtifact) {
        if (segment.text.trim().isEmpty) continue;
        children.add(AssistantMarkdown(segment.text));
        continue;
      }
      if (crepusRenders(segment.text)) {
        children.add(_artifact(context, segment.text));
      } else {
        // Not renderable → show the raw block as a fenced code segment rather
        // than a blank or half-drawn card.
        children.add(AssistantMarkdown('```crepus\n${segment.text}\n```'));
      }
    }
    if (children.isEmpty) return AssistantMarkdown(text);
    if (children.length == 1) return children.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          children[i],
        ],
      ],
    );
  }

  Widget _artifact(BuildContext context, String source) {
    final theme = crepusThemeFor(palette);
    // The single dispatch entry point is the whitelist in `crepus_current.dart`:
    // the only place a model-authored action string becomes an effect. Chat has
    // no completion affordance, so `onComplete` is omitted and `proposedNextStep`
    // is empty (an `accept` with no proposed step is inert).
    void dispatch(String action) => unawaited(
      dispatchCrepusAction(
        action,
        context: context,
        onPrompt: onPrompt,
        proposedNextStep: '',
        onDraftPrompt: onDraftPrompt,
      ),
    );
    return DecoratedBox(
      key: const Key('assistant_crepus_artifact'),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.hairline),
        boxShadow: [
          BoxShadow(
            color: palette.cardShadow,
            offset: const Offset(0, 4),
            blurRadius: 16,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: CrepusView.fromSource(source, theme: theme, onAction: dispatch),
      ),
    );
  }
}

/// Scans `text` for fenced blocks opened by a line whose info-string is exactly
/// `crepus` and returns the ordered segments. Everything outside such a fence
/// (including other code fences) stays markdown and is handed through verbatim.
List<_Segment> _splitSegments(String text) {
  final fence = RegExp(
    r'^([ \t]*)```[ \t]*crepus[ \t]*\r?\n(.*?)\r?\n[ \t]*```[ \t]*$',
    multiLine: true,
    dotAll: true,
  );
  final segments = <_Segment>[];
  var cursor = 0;
  for (final match in fence.allMatches(text)) {
    if (match.start > cursor) {
      segments.add(_Segment.markdown(text.substring(cursor, match.start)));
    }
    segments.add(_Segment.artifact(match.group(2) ?? ''));
    cursor = match.end;
  }
  if (cursor < text.length) {
    segments.add(_Segment.markdown(text.substring(cursor)));
  }
  if (segments.isEmpty) segments.add(_Segment.markdown(text));
  return segments;
}
