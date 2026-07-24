import 'package:flutter/material.dart';

import '../memory/memory_models.dart';

// The digest surfaces borrow the companion's paper voice so the tile and the
// full-window recap resolve the same colours the rest of the home does. Kept
// local to this file rather than reaching into the shell's private palette.
const _paper = Color(0xfff7f6f1);
const _cream = Color(0xfffffcec);
const _ink = Color(0xff171716);
const _inkSoft = Color(0xff706e68);
const _hairline = Color(0x14171716);
const _inkSheet = Color(0xff1c1c1a);

bool _dark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _pageInk(BuildContext context) => _dark(context) ? _cream : _ink;

Color _pageInkSoft(BuildContext context) =>
    _dark(context) ? const Color(0xffa6a49c) : _inkSoft;

/// Whether the platform is asking for calmer motion. The paged view honours it
/// by dropping its entrance animation and letting swipes settle without a
/// spring flourish.
bool _reducedMotion(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations ?? false;

/// Picks the digest to surface for a given moment: the most recent local date
/// wins, and within that date the time of day chooses — the daily "what you
/// need to do" brief before noon, the nightly "what you did" recap after — with
/// the other kind as the fallback when only one was generated. Returns null
/// when there is nothing to show.
MemoryDigest? selectDigestForMoment(List<MemoryDigest> digests, DateTime now) {
  if (digests.isEmpty) return null;
  final latestDate = digests
      .map((digest) => digest.localDate)
      .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
  final sameDate = digests
      .where((digest) => digest.localDate == latestDate)
      .toList();
  final preferred = now.hour < 12 ? DigestKind.daily : DigestKind.nightly;
  for (final digest in sameDate) {
    if (digest.kind == preferred) return digest;
  }
  return sameDate.first;
}

String _tileTitle(DigestKind kind) =>
    kind == DigestKind.nightly ? 'Your night' : 'Your day';

String _tileSubtitle(DigestKind kind) => kind == DigestKind.nightly
    ? "Here's what you did today."
    : "Here's what you need to do.";

String _heroLead(DigestKind kind) =>
    kind == DigestKind.nightly ? "Here's what you did" : "Here's your day";

IconData _kindIcon(DigestKind kind) => kind == DigestKind.nightly
    ? Icons.nightlight_round
    : Icons.wb_twilight_rounded;

// Morning warmth for the daily brief, dusk for the nightly recap. Both stay in
// the paper family so the tile reads as one of the home's cards.
List<Color> _tileGradient(DigestKind kind, bool dark) {
  if (kind == DigestKind.nightly) {
    return dark
        ? const [Color(0xff262a3a), Color(0xff2c2740)]
        : const [Color(0xffe4e6f5), Color(0xffe9e0f2)];
  }
  return dark
      ? const [Color(0xff2f2a24), Color(0xff322a26)]
      : const [Color(0xffffe9d8), Color(0xfffff2df)];
}

/// The compact "Today's recap" tile that lives near the top of the companion
/// scroll — the phone's equivalent of the desktop hub's primary call to
/// action. One tap opens the full-window paged recap.
class MobileDigestTile extends StatelessWidget {
  const MobileDigestTile({required this.digest, this.onOpen, super.key});

  final MemoryDigest digest;

  /// Injected so tests can observe the tap without a live Navigator; defaults
  /// to pushing [MobileDigestView] as a full-screen route.
  final void Function(BuildContext context, MemoryDigest digest)? onOpen;

  static final BorderRadius _radius = BorderRadius.circular(18);

  void _open(BuildContext context) {
    final handler = onOpen;
    if (handler != null) {
      handler(context, digest);
      return;
    }
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        fullscreenDialog: true,
        opaque: true,
        transitionDuration: _reducedMotion(context)
            ? Duration.zero
            : const Duration(milliseconds: 320),
        pageBuilder: (_, _, _) => MobileDigestView(digest: digest),
        transitionsBuilder: (context, animation, _, child) =>
            _reducedMotion(context)
            ? child
            : FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = _dark(context);
    final snippet = digest.items.isEmpty
        ? _tileSubtitle(digest.kind)
        : digest.items.first;
    return DecoratedBox(
      key: const Key('companion_digest_tile'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _tileGradient(digest.kind, dark),
        ),
        border: Border.all(color: dark ? const Color(0x1ffffcec) : _hairline),
        borderRadius: _radius,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const Key('companion_digest_tile_open'),
          onTap: () => _open(context),
          borderRadius: _radius,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
            child: Row(
              children: [
                Icon(_kindIcon(digest.kind), color: _pageInk(context)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _tileTitle(digest.kind),
                        style: TextStyle(
                          color: _pageInk(context),
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        snippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _pageInkSoft(context),
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: _pageInkSoft(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The full-window, Wrapped-style recap: a swipeable run of 2–3 pages that
/// walks through one digest — a hero, then the items as visually distinct
/// panels — with a page indicator and a close button.
class MobileDigestView extends StatefulWidget {
  const MobileDigestView({required this.digest, super.key});

  final MemoryDigest digest;

  @override
  State<MobileDigestView> createState() => _MobileDigestViewState();
}

class _MobileDigestViewState extends State<MobileDigestView> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Hero first, then the remaining items split into one or two panels so the
  // experience always lands at two or three pages — one idea per page.
  List<List<String>> _panels() {
    final items = widget.digest.items;
    if (items.length <= 1) return const [];
    final rest = items.sublist(1);
    if (rest.length <= 3) return [rest];
    final mid = (rest.length / 2).ceil();
    return [rest.sublist(0, mid), rest.sublist(mid)];
  }

  @override
  Widget build(BuildContext context) {
    final dark = _dark(context);
    final panels = _panels();
    final pages = <Widget>[
      _DigestHero(digest: widget.digest),
      for (var i = 0; i < panels.length; i++)
        _DigestPanel(
          kind: widget.digest.kind,
          items: panels[i],
          startIndex: 2 + panels.take(i).fold<int>(0, (n, p) => n + p.length),
        ),
    ];
    return Scaffold(
      key: const Key('companion_digest_view'),
      backgroundColor: dark ? _inkSheet : _paper,
      body: SafeArea(
        child: Stack(
          children: [
            PageView(
              key: const Key('companion_digest_pages'),
              controller: _controller,
              physics: _reducedMotion(context)
                  ? const ClampingScrollPhysics()
                  : const BouncingScrollPhysics(),
              onPageChanged: (page) => setState(() => _page = page),
              children: pages,
            ),
            Positioned(
              top: 4,
              right: 8,
              child: IconButton(
                key: const Key('companion_digest_close'),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(Icons.close_rounded, color: _pageInk(context)),
              ),
            ),
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: _PageDots(count: pages.length, active: _page),
            ),
          ],
        ),
      ),
    );
  }
}

class _DigestHero extends StatelessWidget {
  const _DigestHero({required this.digest});

  final MemoryDigest digest;

  @override
  Widget build(BuildContext context) {
    final items = digest.items;
    final standout = items.isEmpty ? null : items.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 72, 28, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(_kindIcon(digest.kind), size: 40, color: _pageInkSoft(context)),
          const SizedBox(height: 24),
          Text(
            _heroLead(digest.kind),
            style: TextStyle(
              color: _pageInkSoft(context),
              fontSize: 20,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 16),
          if (standout != null)
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  standout,
                  style: TextStyle(
                    color: _pageInk(context),
                    fontSize: 34,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            )
          else
            Text(
              _tileSubtitle(digest.kind),
              style: TextStyle(
                color: _pageInk(context),
                fontSize: 26,
                height: 1.2,
                fontWeight: FontWeight.w700,
              ),
            ),
          const Spacer(),
          if (items.length > 1)
            Text(
              '${items.length} things — swipe to see them all',
              style: TextStyle(color: _pageInkSoft(context), fontSize: 14),
            ),
        ],
      ),
    );
  }
}

class _DigestPanel extends StatelessWidget {
  const _DigestPanel({
    required this.kind,
    required this.items,
    required this.startIndex,
  });

  final DigestKind kind;
  final List<String> items;
  final int startIndex;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 72, 28, 96),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          kind == DigestKind.nightly ? 'And also' : 'On your list',
          style: TextStyle(
            color: _pageInkSoft(context),
            fontSize: 18,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 24),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: 20),
                  _PanelItem(index: startIndex + i, text: items[i]),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _PanelItem extends StatelessWidget {
  const _PanelItem({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '$index',
        style: TextStyle(
          color: _pageInkSoft(context),
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            color: _pageInk(context),
            fontSize: 22,
            height: 1.3,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  );
}

class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.active});

  final int count;
  final int active;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      for (var i = 0; i < count; i++)
        AnimatedContainer(
          duration: _reducedMotion(context)
              ? Duration.zero
              : const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: i == active ? 22 : 7,
          height: 7,
          decoration: BoxDecoration(
            color: i == active
                ? _pageInk(context)
                : _pageInkSoft(context).withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
    ],
  );
}
