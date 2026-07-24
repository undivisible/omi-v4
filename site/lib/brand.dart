/// The brand constants the site shares with the app.
///
/// The palette is not re-picked here: every value is transcribed from
/// `_HubColors.dark` in `app/lib/features/chat_screen.dart`, so the site and
/// the product read as one thing. The stylesheet at `web/styles.css` holds the
/// same values as custom properties; these exist for the places that need a
/// colour inside generated markup (the favicon, the diagram fills).
library;

const inkColor = '#171716';
const creamColor = '#fffcec';
const mutedColor = '#a6a49c';
const skyColor = '#9aa0ff';

/// The Omi mark: eight dots in a ring, each individually addressable.
///
/// Geometry is measured from `app/assets/images/omi_logo.png` (260x260) by
/// connected-component analysis of the alpha channel, and is mirrored from the
/// hand-authored source of truth at `app/assets/images/omi_mark.svg`. Ring
/// centre is (129.5, 129.5); every dot has radius 17.2. The four dots on the
/// axes sit at radius 86.71, the four on the diagonals at radius 91.92 — the
/// mark is a rounded square, not a perfect circle, and that asymmetry is
/// deliberate in the original artwork, so it is preserved here.
///
/// `d1` is due north and `d2`..`d8` continue clockwise. `web/mark.js` animates
/// them in that order: a travelling pulse walks d1 -> d8, and the whole ring
/// orbits about the centre.
const markCentre = 129.5;
const markDotRadius = 17.2;
const markAxisRadius = 86.71;
const markDiagonalRadius = 91.92;

/// One dot of the mark: its position, and the unit vector pointing away from
/// the ring's centre that `--omi-spread` scales to scatter it.
class MarkDot {
  const MarkDot(this.id, this.cx, this.cy, this.ux, this.uy);

  final String id;
  final double cx;
  final double cy;
  final double ux;
  final double uy;
}

/// Written out rather than computed so the shipped numbers are the measured
/// ones, reviewable against the source SVG without running anything.
const markDots = <MarkDot>[
  MarkDot('d1', 129.5, 42.79, 0, -1),
  MarkDot('d2', 194.5, 64.5, 0.7071, -0.7071),
  MarkDot('d3', 216.21, 129.5, 1, 0),
  MarkDot('d4', 194.5, 194.5, 0.7071, 0.7071),
  MarkDot('d5', 129.5, 216.21, 0, 1),
  MarkDot('d6', 64.5, 194.5, -0.7071, 0.7071),
  MarkDot('d7', 42.79, 129.5, -1, 0),
  MarkDot('d8', 64.5, 64.5, -0.7071, -0.7071),
];
