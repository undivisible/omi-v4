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
  const _Segment.markdown(this.text) : isArtifact = false, complete = true;
  const _Segment.artifact(this.text, {this.complete = true})
    : isArtifact = true;

  final String text;
  final bool isArtifact;
  final bool complete;
}

/// Splits assistant `text` on fenced blocks whose info-string is exactly
/// `crepus` (```crepus\n<source>\n```) and renders each segment:
///   * markdown → the existing [AssistantMarkdown] (byte-identical behaviour),
///   * a valid crepus block → an artifact card drawing [CrepusView.fromSource],
///     with every unsourced chart removed by [stripUnsourcedCharts] first,
///   * an invalid crepus block → the raw fenced block back through
///     [AssistantMarkdown] as a plain code segment (graceful fallback).
///
/// While [streaming] is true, an open ```crepus fence without a closing fence
/// shows a skeleton placeholder instead of leaking raw source into markdown.
/// Completed artifacts fade in once streaming ends.
///
/// A message with no ```crepus fence renders as a single markdown segment, so
/// today's output is preserved exactly.
class AssistantContent extends StatelessWidget {
  const AssistantContent(
    this.text, {
    required this.onPrompt,
    required this.onDraftPrompt,
    required this.palette,
    this.streaming = false,
    super.key,
  });

  final String text;
  final ValueChanged<String> onPrompt;
  final ValueChanged<String> onDraftPrompt;
  final CrepusCurrentPalette palette;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final segments = _splitSegments(text, streaming: streaming);
    // No artifact fence → render exactly as before: a single markdown widget.
    if (segments.length == 1 && !segments.first.isArtifact) {
      return AssistantMarkdown(segments.first.text, streaming: streaming);
    }
    final children = <Widget>[];
    for (final segment in segments) {
      if (!segment.isArtifact) {
        if (segment.text.trim().isEmpty) continue;
        children.add(AssistantMarkdown(segment.text, streaming: streaming));
        continue;
      }
      if (streaming || !segment.complete) {
        children.add(const _ArtifactSkeleton());
        continue;
      }
      final source = stripUnsourcedCharts(segment.text);
      // Nothing survived the chart strip: the artifact was only an invented
      // plot, and there is nothing left worth drawing.
      if (source.trim().isEmpty) continue;
      if (crepusRenders(source)) {
        children.add(_ArtifactFadeIn(child: _artifact(context, source)));
      } else {
        // Not renderable → show the raw block as a fenced code segment rather
        // than a blank or half-drawn card.
        children.add(
          AssistantMarkdown('```crepus\n$source\n```', streaming: streaming),
        );
      }
    }
    if (children.isEmpty) return AssistantMarkdown(text, streaming: streaming);
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

/// Placeholder card shown while a ```crepus artifact is still streaming in.
class _ArtifactSkeleton extends StatefulWidget {
  const _ArtifactSkeleton();

  @override
  State<_ArtifactSkeleton> createState() => _ArtifactSkeletonState();
}

class _ArtifactSkeletonState extends State<_ArtifactSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: .14);
    return DecoratedBox(
      key: const Key('assistant_crepus_artifact_skeleton'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: .35),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) {
            final t = 0.45 + 0.55 * _pulse.value;
            Color bar(double widthFactor) => Color.lerp(
              muted.withValues(alpha: .55),
              muted,
              t * widthFactor,
            )!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 10,
                  width: 96,
                  decoration: BoxDecoration(
                    color: bar(.9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  height: 8,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: bar(.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 8,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: bar(.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 8,
                  width: 220,
                  decoration: BoxDecoration(
                    color: bar(.35),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ArtifactFadeIn extends StatelessWidget {
  const _ArtifactFadeIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) =>
          Opacity(opacity: value.clamp(0.0, 1.0), child: child),
      child: child,
    );
  }
}

/// Element names that plot a series. `sparkline` is the only one the renderer
/// draws; the rest are spellings a model reaches for when it wants a chart.
const Set<String> _chartElements = {
  'sparkline',
  'chart',
  'linechart',
  'line-chart',
  'barchart',
  'bar-chart',
  'areachart',
  'area-chart',
  'graph',
  'plot',
  'series',
};

final RegExp _chartSourceAttribute = RegExp(
  r'(?<![A-Za-z0-9_-])source[_-]?=\s*(?:"([^"]*)"|\{([^}]*)\}|(\S+))',
  caseSensitive: false,
);

/// Whether a chart line names the tool result its values came from, as
/// `source=tool:<name>`. Mirrors `chart_values_are_sourced` in
/// `worker-rs/src/crepus_safety.rs`.
bool chartValuesAreSourced(String line) {
  final match = _chartSourceAttribute.firstMatch(line);
  if (match == null) return false;
  final raw = (match.group(1) ?? match.group(2) ?? match.group(3) ?? '')
      .trim()
      .toLowerCase();
  if (!raw.startsWith('tool:')) return false;
  return raw.substring('tool:'.length).trim().isNotEmpty;
}

/// Drops every chart line whose values did not come from a tool result, along
/// with anything nested under it. A model that plots numbers it never measured
/// produces something that reads as evidence, which is worse than no chart at
/// all; the same rule runs server-side in `worker-rs/src/crepus_safety.rs`.
String stripUnsourcedCharts(String source) {
  final kept = <String>[];
  int? dropping;
  for (final line in source.split('\n')) {
    if (line.trim().isEmpty) {
      if (dropping == null) kept.add(line);
      continue;
    }
    final indent = line.length - line.trimLeft().length;
    if (dropping != null) {
      if (indent > dropping) continue;
      dropping = null;
    }
    final trimmed = line.trimLeft();
    final end = trimmed.indexOf(RegExp(r'\s'));
    final element = (end < 0 ? trimmed : trimmed.substring(0, end))
        .toLowerCase();
    if (_chartElements.contains(element) && !chartValuesAreSourced(line)) {
      dropping = indent;
      continue;
    }
    kept.add(line);
  }
  return kept.join('\n');
}

/// Scans `text` for fenced blocks opened by a line whose info-string is exactly
/// `crepus` and returns the ordered segments. Everything outside such a fence
/// (including other code fences) stays markdown and is handed through verbatim.
///
/// When [streaming] is true, a trailing open ```crepus fence (no closing fence
/// yet) is split out as an incomplete artifact segment rather than markdown.
List<_Segment> _splitSegments(String text, {bool streaming = false}) {
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
  final tail = text.substring(cursor);
  if (tail.isNotEmpty) {
    if (streaming) {
      _splitStreamingTail(tail, segments);
    } else {
      segments.add(_Segment.markdown(tail));
    }
  }
  if (segments.isEmpty) segments.add(_Segment.markdown(text));
  return segments;
}

void _splitStreamingTail(String tail, List<_Segment> segments) {
  final openFence = RegExp(
    r'```[ \t]*crepus[ \t]*(?:\r?\n|\r)(.*)$',
    dotAll: true,
  );
  final match = openFence.firstMatch(tail);
  if (match != null) {
    final before = tail.substring(0, match.start);
    if (before.trim().isNotEmpty) {
      segments.add(_Segment.markdown(before));
    }
    segments.add(_Segment.artifact(match.group(1) ?? '', complete: false));
    return;
  }
  final openingOnly = RegExp(r'```[ \t]*crepus[ \t]*$');
  if (openingOnly.hasMatch(tail)) {
    final before = tail.substring(0, openingOnly.matchAsPrefix(tail)!.start);
    if (before.trim().isNotEmpty) {
      segments.add(_Segment.markdown(before));
    }
    segments.add(const _Segment.artifact('', complete: false));
    return;
  }
  segments.add(_Segment.markdown(tail));
}
