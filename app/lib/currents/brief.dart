import 'dart:async';

import 'package:crepuscularity_flutter/crepuscularity_flutter.dart';
import 'package:flutter/material.dart';

import '../features/hub_task_meta.dart';
import 'crepus_current.dart';
import 'currents_client.dart';

/// One current as the brief reads it: the card plus its decoded task metadata,
/// which is where a meeting's time range and participants live.
final class BriefEntry {
  const BriefEntry({required this.card, this.meta});

  final CurrentCard card;
  final HubTaskMeta? meta;

  String get title => meta?.title ?? card.title;

  String get summary => card.summary;

  String? get detail => meta?.detail;

  DateTime? get startsAt => meta?.startsAt?.toLocal();

  DateTime? get endsAt => meta?.endsAt?.toLocal();

  /// When a scheduled entry stops being "now": its end, or an hour after its
  /// start when no end was given.
  DateTime? get _until {
    final start = startsAt;
    if (start == null) return null;
    return endsAt ?? start.add(const Duration(hours: 1));
  }

  String? get crepus => currentCrepusSource(card.metadata);
}

/// The composed brief: one hero and the few things after it.
final class BriefPlan {
  const BriefPlan({required this.hero, required this.rest});

  final BriefEntry? hero;
  final List<BriefEntry> rest;

  bool get isEmpty => hero == null;
}

/// Chooses what the brief leads with.
const _promotionalMailMarkers = <String>{
  'coupon',
  'deal',
  'discount',
  'flash sale',
  'limited-time',
  'limited time',
  'newsletter',
  'offer',
  'promo',
  'sale',
  'unsubscribe',
};

bool _isPromotionalMail(BriefEntry entry) {
  final source = [
    entry.card.sourceKind,
    ...entry.card.item.evidence.map((evidence) => evidence.sourceId),
  ].whereType<String>().join(' ').toLowerCase();
  if (!source.contains('mail') && !source.contains('email')) return false;
  final content = [
    entry.title,
    entry.summary,
    entry.card.item.reason,
    ...entry.card.item.evidence.map((evidence) => evidence.reason),
  ].join(' ').toLowerCase();
  return _promotionalMailMarkers.any(content.contains);
}

/// Chooses what the brief leads with.
///
/// A scheduled thing that has not finished yet wins — the soonest one, because
/// that is the thing the user is about to walk into. With nothing scheduled the
/// most confident current leads instead, and the remainder keep their incoming
/// order so the brief stays stable between refreshes.
BriefPlan planBrief(
  List<CurrentCard> cards, {
  required DateTime now,
  int maxRest = 3,
}) {
  final entries = [
    for (final card in cards)
      BriefEntry(
        card: card,
        meta: card.metadata == null
            ? null
            : HubTaskMeta.fromJson(card.metadata!),
      ),
  ];
  if (entries.isEmpty) return const BriefPlan(hero: null, rest: []);
  final preferred = entries
      .where((entry) => !_isPromotionalMail(entry))
      .toList();
  // If everything available is bulk mail, retain it rather than leaving the
  // user with a blank brief. Otherwise it cannot lead or crowd out real work.
  final prioritized = preferred.isEmpty ? entries : preferred;

  final scheduled = prioritized.where((entry) {
    final until = entry._until;
    return until != null && until.isAfter(now);
  }).toList()..sort((a, b) => a.startsAt!.compareTo(b.startsAt!));

  final hero = scheduled.isNotEmpty
      ? scheduled.first
      : prioritized.reduce(
          (best, entry) =>
              entry.card.item.confidence > best.card.item.confidence
              ? entry
              : best,
        );
  final rest = [
    for (final entry in prioritized)
      if (!identical(entry, hero)) entry,
    for (final entry in entries)
      if (_isPromotionalMail(entry) && !identical(entry, hero)) entry,
  ];
  return BriefPlan(hero: hero, rest: rest.take(maxRest).toList());
}

/// How long until (or since) a moment, in the brief's voice.
String briefCountdown(DateTime start, DateTime now) {
  final delta = start.difference(now);
  if (delta.inSeconds.abs() < 60) return 'Now';
  if (delta.isNegative) {
    final ago = -delta.inMinutes;
    if (ago < 60) return 'Started $ago min ago';
    final hours = ago ~/ 60;
    return 'Started $hours hr ago';
  }
  if (delta.inMinutes < 60) return 'In ${delta.inMinutes} min';
  final hours = delta.inHours;
  final minutes = delta.inMinutes - hours * 60;
  if (delta.inHours < 12) {
    return minutes == 0 ? 'In $hours hr' : 'In $hours hr $minutes min';
  }
  return 'In $hours hr';
}

/// The "what matters right now" brief: one dominant hero and the next few
/// things under it.
///
/// The hero is composed by the model — it emits constrained `.crepus`, which
/// [CrepusView] renders through the same action whitelist the classic row uses.
/// When that source is missing, malformed, or reaches for a node the renderer
/// does not support, the hand-built brief below takes over, so this surface is
/// never blank and never half-drawn.
class CurrentsBrief extends StatefulWidget {
  const CurrentsBrief({
    required this.cards,
    required this.palette,
    required this.onPrompt,
    this.briefCrepus,
    this.onDraftPrompt,
    this.onComplete,
    this.now,
    this.compact = false,
    super.key,
  });

  final List<CurrentCard> cards;
  final CrepusCurrentPalette palette;
  final ValueChanged<String> onPrompt;

  /// Hub-composed infographic for the whole brief. When this renders, the
  /// hand-built hero and THEN rows stay hidden so the model's layout is not
  /// duplicated underneath.
  final String? briefCrepus;

  /// Drafts text into the composer without sending it. Model-authored
  /// `prompt:` actions land here, never on [onPrompt].
  final ValueChanged<String>? onDraftPrompt;
  final ValueChanged<String>? onComplete;

  /// Fixed clock for tests; production reads the wall clock and re-reads it on
  /// a slow tick so the countdown stays honest.
  final DateTime? now;

  /// Tighter typography and fewer rows for the marketing embed.
  final bool compact;

  @override
  State<CurrentsBrief> createState() => _CurrentsBriefState();
}

class _CurrentsBriefState extends State<CurrentsBrief> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    if (widget.now == null) {
      _tick = Timer.periodic(
        const Duration(seconds: 30),
        (_) => setState(() {}),
      );
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now ?? DateTime.now();
    final compact = widget.compact;
    final plan = planBrief(widget.cards, now: now, maxRest: compact ? 2 : 3);
    final palette = widget.palette;
    // Currents are action surfaces. A model-composed visualization may be
    // useful as supporting content later, but it must never replace the
    // deterministic hero, action controls, or secondary rows.
    final hero = plan.hero;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hero == null)
          _BriefShell(
            palette: palette,
            compact: compact,
            child: _BriefEyebrow(
              palette: palette,
              label: 'Clear',
              trailing: 'Nothing scheduled',
            ),
          )
        else
          _BriefHero(
            key: const Key('brief_hero'),
            entry: hero,
            palette: palette,
            now: now,
            compact: compact,
            onPrompt: widget.onPrompt,
            onDraftPrompt: widget.onDraftPrompt,
            onComplete: widget.onComplete,
          ),
        if (plan.rest.isNotEmpty) ...[
          SizedBox(height: compact ? 10 : 20),
          Padding(
            padding: EdgeInsets.only(left: 2, bottom: compact ? 0 : 4),
            child: Text(
              'THEN',
              style: TextStyle(
                fontSize: compact ? 9 : 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.17,
                color: palette.muted,
              ),
            ),
          ),
          for (final entry in plan.rest)
            _BriefRow(
              key: ValueKey('brief_row_${entry.card.item.id}'),
              entry: entry,
              palette: palette,
              now: now,
              compact: compact,
              onPrompt: widget.onPrompt,
              onDraftPrompt: widget.onDraftPrompt,
              onComplete: widget.onComplete,
            ),
        ],
      ],
    );
  }
}

/// The hero card's chrome, shared by the AI-composed and hand-built versions so
/// a fallback is a different interior, never a different surface.
class _BriefShell extends StatelessWidget {
  const _BriefShell({
    required this.palette,
    required this.child,
    this.compact = false,
  });

  final CrepusCurrentPalette palette;
  final Widget child;
  final bool compact;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: palette.cardBg,
      borderRadius: BorderRadius.circular(compact ? 14 : 20),
      border: Border.all(color: palette.hairline),
      boxShadow: [
        BoxShadow(
          color: palette.cardShadow,
          offset: Offset(0, compact ? 4 : 8),
          blurRadius: compact ? 16 : 28,
        ),
      ],
    ),
    child: Padding(padding: EdgeInsets.all(compact ? 12 : 20), child: child),
  );
}

class _BriefEyebrow extends StatelessWidget {
  const _BriefEyebrow({
    required this.palette,
    required this.label,
    this.trailing,
    this.contentKind,
  });

  final CrepusCurrentPalette palette;
  final String label;
  final String? trailing;
  final CurrentContentKind? contentKind;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (contentKind case final kind?)
        _ContentKindBadge(kind: kind, palette: palette),
      if (contentKind != null) const SizedBox(width: 8),
      Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.17,
          color: palette.muted,
        ),
      ),
      const Spacer(),
      if (trailing case final trailing?)
        Text(
          trailing,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: palette.accent,
          ),
        ),
    ],
  );
}

class _BriefHero extends StatelessWidget {
  const _BriefHero({
    required this.entry,
    required this.palette,
    required this.now,
    required this.onPrompt,
    this.onDraftPrompt,
    this.onComplete,
    this.compact = false,
    super.key,
  });

  final BriefEntry entry;
  final CrepusCurrentPalette palette;
  final DateTime now;
  final ValueChanged<String> onPrompt;

  /// Drafts text into the composer without sending it. Model-authored
  /// `prompt:` actions land here, never on [onPrompt].
  final ValueChanged<String>? onDraftPrompt;
  final ValueChanged<String>? onComplete;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // Generated layout is deliberately not rendered here. Current cards must
    // retain their fixed action affordances, even when a model supplies a
    // valid-looking visualization.
    final shell = _BriefShell(
      palette: palette,
      compact: compact,
      child: _heroBody(),
    );
    // Reduced motion keeps the brief still: it is an infographic, and the
    // entrance is decoration, not information.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return shell;
    return TweenAnimationBuilder<double>(
      key: ValueKey(entry.card.item.id),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      builder: (context, value, child) =>
          Opacity(opacity: value, child: child!),
      child: shell,
    );
  }

  Widget _heroBody() {
    final start = entry.startsAt;
    final range = entry.meta?.formatTimeRange();
    final prep = entry.card.item.proposedNextStep;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BriefEyebrow(
          palette: palette,
          label: start == null ? 'Now' : 'Next up',
          trailing: start == null ? null : briefCountdown(start, now),
          contentKind: entry.card.contentKind,
        ),
        SizedBox(height: compact ? 6 : 10),
        Text(
          entry.title,
          key: const Key('brief_hero_title'),
          maxLines: compact ? 2 : null,
          overflow: compact ? TextOverflow.ellipsis : null,
          style: TextStyle(
            fontSize: compact ? 18 : 28,
            fontWeight: FontWeight.w500,
            letterSpacing: compact ? -0.6 : -1.1,
            height: 1.15,
            color: palette.ink,
          ),
        ),
        if (!compact && (range != null || entry.detail != null)) ...[
          const SizedBox(height: 8),
          Text(
            [range, entry.detail].whereType<String>().join('  ·  '),
            style: TextStyle(fontSize: 13, color: palette.muted),
          ),
        ],
        if (!compact && entry.summary.trim().isNotEmpty) ...[
          const SizedBox(height: 14),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: palette.hairline)),
            ),
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                entry.summary,
                style: TextStyle(fontSize: 14, height: 1.4, color: palette.ink),
              ),
            ),
          ),
        ],
        if (!compact) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              _BriefAction(
                key: const Key('brief_hero_prep'),
                palette: palette,
                label: 'Prep me →',
                emphasis: true,
                onTap: () => onPrompt(prep),
              ),
              if (onComplete != null) ...[
                const SizedBox(width: 16),
                _BriefAction(
                  key: const Key('brief_hero_done'),
                  palette: palette,
                  label: 'Done',
                  onTap: () => onComplete!(entry.card.item.id),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

class _BriefAction extends StatelessWidget {
  const _BriefAction({
    required this.palette,
    required this.label,
    required this.onTap,
    this.emphasis = false,
    super.key,
  });

  final CrepusCurrentPalette palette;
  final String label;
  final VoidCallback onTap;
  final bool emphasis;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    hoverColor: palette.rowHover,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: emphasis ? palette.accent : palette.muted,
        ),
      ),
    ),
  );
}

/// A supporting line of the brief: quieter than the hero, still readable at a
/// glance — time on the left, what it is on the right.
class _BriefRow extends StatelessWidget {
  const _BriefRow({
    required this.entry,
    required this.palette,
    required this.now,
    required this.onPrompt,
    this.onDraftPrompt,
    this.onComplete,
    this.compact = false,
    super.key,
  });

  final BriefEntry entry;
  final CrepusCurrentPalette palette;
  final DateTime now;
  final ValueChanged<String> onPrompt;

  /// Drafts text into the composer without sending it. Model-authored
  /// `prompt:` actions land here, never on [onPrompt].
  final ValueChanged<String>? onDraftPrompt;
  final ValueChanged<String>? onComplete;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // Supporting Currents keep the same native interaction contract as the
    // hero. Model-authored layouts may not replace or intercept this row.
    final start = entry.startsAt;
    final lead = start == null
        ? (entry.card.sourceKind ??
                  currentContentKindLabel(entry.card.contentKind))
              .toUpperCase()
        : briefCountdown(start, now).toUpperCase();
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.hairline)),
      ),
      child: InkWell(
        onTap: () => onPrompt(entry.card.item.proposedNextStep),
        hoverColor: palette.rowHover,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: compact ? 7 : 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: compact ? 68 : 96,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ContentKindBadge(
                      kind: entry.card.contentKind,
                      palette: palette,
                      compact: compact,
                    ),
                    if (lead.isNotEmpty) ...[
                      SizedBox(height: compact ? 4 : 6),
                      Text(
                        lead,
                        maxLines: compact ? 2 : null,
                        overflow: compact ? TextOverflow.ellipsis : null,
                        style: TextStyle(
                          fontSize: compact ? 9 : 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.17,
                          color: palette.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: compact ? 1 : null,
                      overflow: compact ? TextOverflow.ellipsis : null,
                      style: TextStyle(
                        fontSize: compact ? 13 : 15,
                        fontWeight: FontWeight.w500,
                        letterSpacing: compact ? -0.2 : -0.3,
                        color: palette.ink,
                      ),
                    ),
                    if (!compact && entry.summary.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          entry.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: palette.muted),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContentKindBadge extends StatelessWidget {
  const _ContentKindBadge({
    required this.kind,
    required this.palette,
    this.compact = false,
  });

  final CurrentContentKind kind;
  final CrepusCurrentPalette palette;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (kind) {
      CurrentContentKind.agentAction => ('Omi', palette.accent),
      CurrentContentKind.humanAction => ('You', palette.ink),
      CurrentContentKind.awareness => ('Know', palette.muted),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: palette.hairline),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 4 : 6,
          vertical: compact ? 1 : 2,
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: compact ? 7 : 8,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: color,
          ),
        ),
      ),
    );
  }
}
