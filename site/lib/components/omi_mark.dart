import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../brand.dart';

/// The eight-dot Omi mark, rendered as inline SVG.
///
/// The markup is emitted as a string because SVG needs its own namespace and
/// per-dot custom properties; building it from [markDots] keeps one source of
/// geometry for every size the mark appears at. Every dot carries `--ux`/`--uy`
/// so the stylesheet can scatter the ring radially, and the ids `d1`..`d8` so
/// the pulse can walk it in order.
///
/// Without `web/mark.js` — or under `prefers-reduced-motion` — this renders as
/// the correct static ring and nothing schedules a frame.
class OmiMark extends StatelessComponent {
  const OmiMark({
    this.variant,
    this.glow = false,
    this.decorative = true,
    super.key,
  });

  /// The lead mark on a page: larger, and lit by the glow filter.
  const OmiMark.hero({Key? key})
    : this(glow: true, decorative: false, key: key);

  /// The lead mark on a secondary page: the same, one step down in size.
  const OmiMark.heroSmall({Key? key})
    : this(variant: 'omi-mark--sm', glow: true, decorative: false, key: key);

  /// The mark at the head of the section rail. It is turned by how far down
  /// the page the reader is, so it doubles as a scroll indicator; `web/mark.js`
  /// drives it separately from the ambient drift the other marks carry.
  const OmiMark.rail({Key? key})
    : this(variant: 'omi-mark--rail', decorative: false, key: key);

  const OmiMark.nav({Key? key}) : this(variant: 'omi-mark--nav', key: key);

  const OmiMark.footer({Key? key}) : this(variant: 'omi-mark--foot', key: key);

  /// An extra class selecting one of the three sizes, or null for the default.
  final String? variant;

  /// Whether to light the ring with the soft halo filter.
  final bool glow;

  /// A decorative mark is hidden from assistive technology; the lead mark on a
  /// page is announced as the image it is.
  final bool decorative;

  @override
  Component build(BuildContext context) => RawText(markup());

  String markup() {
    final classes = ['omi-mark', if (variant != null) variant!].join(' ');
    // A unique filter id per mark, so several marks on one page never collide.
    final filterId = 'omiMarkGlow-${variant ?? 'lead'}';
    final role = decorative
        ? 'aria-hidden="true"'
        : 'role="img" aria-label="Omi"';

    final dots = markDots
        .map(
          (d) =>
              '<circle id="${d.id}" cx="${d.cx}" cy="${d.cy}" '
              'r="$markDotRadius" style="--ux:${d.ux};--uy:${d.uy}"/>',
        )
        .join();

    final defs = glow
        ? '<defs><filter id="$filterId" x="-40%" y="-40%" width="180%" '
              'height="180%" color-interpolation-filters="sRGB">'
              '<feGaussianBlur in="SourceGraphic" stdDeviation="9" result="soft"/>'
              '<feColorMatrix in="soft" type="matrix" result="halo" '
              'values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 0.85 0"/>'
              '<feMerge><feMergeNode in="halo"/><feMergeNode in="halo"/>'
              '<feMergeNode in="SourceGraphic"/></feMerge></filter></defs>'
        : '';
    final ring = glow
        ? '<g class="omi-mark-ring" filter="url(#$filterId)">'
        : '<g class="omi-mark-ring">';

    return '<svg class="$classes" viewBox="0 0 260 260" $role '
        'data-omi-mark>$defs$ring$dots</g></svg>';
  }
}

/// The mark reduced to a favicon: the same eight dots on the ink square,
/// scaled from the 260-unit ring to 32. Inlined as a data URI so the page
/// makes no extra request and the icon needs no build step of its own.
String faviconDataUri() {
  const scale = 32 / 260.0;
  final dots = markDots.map((d) {
    final cx = (d.cx * scale).toStringAsFixed(2);
    final cy = (d.cy * scale).toStringAsFixed(2);
    return '<circle cx="$cx" cy="$cy" r="2.12" fill="$creamColor"/>';
  }).join();
  final svg =
      "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'>"
      "<rect width='32' height='32' rx='7' fill='$inkColor'/>$dots</svg>";
  return 'data:image/svg+xml,${Uri.encodeComponent(svg)}';
}
