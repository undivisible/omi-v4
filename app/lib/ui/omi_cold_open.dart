import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'omi_mark_anchor.dart';
import 'omi_orb.dart';

/// The cold open: the eight dots arrive from off the edges of the screen, lock
/// into the mark, run one lap of [OmiOrbMotion.tusiPendulum], then travel to
/// where the app's own mark already sits and hand over to it.
///
/// The last beat is the whole point. Finishing at the centre of the window and
/// cutting to a hub whose mark lives above the greeting is two screens; moving
/// to that mark's real position and fading out on top of it is one.
///
/// It is the app-launch beat only. Nothing else in the product is allowed to
/// hold the user for three seconds, so nothing else uses it.
class OmiColdOpen extends StatefulWidget {
  const OmiColdOpen({
    required this.onDone,
    this.color,
    this.handoffSize = 64,
    super.key,
  });

  /// Called once, when the mark has reached [handoffSize] and the field has
  /// faded off. Under reduce motion it is called on the first frame instead.
  final VoidCallback onDone;

  final Color? color;

  /// The size the mark leaves at, used when the destination has not reported
  /// where its own mark is. A published anchor supersedes it, because a
  /// measured size cannot be wrong and a constant can.
  final double handoffSize;

  /// Field, converge, lock, showcase, settle, hand off.
  static const Duration duration = Duration(milliseconds: 2400);

  @override
  State<OmiColdOpen> createState() => _OmiColdOpenState();
}

class _OmiColdOpenState extends State<OmiColdOpen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: OmiColdOpen.duration,
  );

  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _clock.addStatusListener((status) {
      if (status == AnimationStatus.completed) _finish();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final quiet =
        debugOmiOrbStatic ||
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false);
    if (quiet) {
      if (_clock.isAnimating) _clock.stop();
      WidgetsBinding.instance.addPostFrameCallback((_) => _finish());
    } else if (!_clock.isAnimating && !_finished) {
      _clock.forward();
    }
  }

  void _finish() {
    if (_finished || !mounted) return;
    _finished = true;
    widget.onDone();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final anchor = OmiMarkAnchorScope.maybeOf(context);
    return Semantics(
      label: 'Omi',
      child: GestureDetector(
        // Three seconds is a long time to hold someone who has already seen it.
        onTap: _finish,
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: Listenable.merge([_clock, ?anchor]),
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: OmiColdOpenPainter(
              progress: _clock.value,
              background: theme.scaffoldBackgroundColor,
              ink: widget.color ?? theme.colorScheme.primary,
              handoffSize: widget.handoffSize,
              handoff: anchor?.value,
            ),
          ),
        ),
      ),
    );
  }
}

/// The beats, as fractions of [OmiColdOpen.duration].
const double _fieldEnd = 0.02;
const double _convergeEnd = 0.34;
const double _showcaseEnd = 0.70;
const double _settleEnd = 0.78;

/// How many points are in the sky the mark arrives through.
const int _starCount = 90;

/// Draws one frame of the open. Public so a preview harness can step the
/// timeline without a ticker.
class OmiColdOpenPainter extends CustomPainter {
  const OmiColdOpenPainter({
    required this.progress,
    required this.background,
    required this.ink,
    required this.handoffSize,
    this.handoff,
  });

  final double progress;

  /// The room the mark arrives in, and the only thing behind it.
  final Color background;

  final Color ink;
  final double handoffSize;

  /// Where the destination's own mark sits, when it has reported. The settle
  /// beat travels here rather than shrinking in place, so the dots end up
  /// exactly where the app is already drawing them.
  final Rect? handoff;

  @override
  void paint(Canvas canvas, Size size) {
    final openSize = math.min(size.shortestSide * 0.46, 260.0);

    // The field goes out first and the mark second, so the last thing on screen
    // is the mark over the app rather than the mark over a black hole.
    // The field goes early and the mark lands late, so the handover is the mark
    // settling onto the app rather than a cut between two screens.
    final fieldAlpha = progress <= _settleEnd
        ? 1.0
        : 1 - Curves.easeInOutCubic.transform(_span(_settleEnd, 0.94));
    if (fieldAlpha > 0) {
      // Flat ink, no plate. A sunrise wash behind the mark meant the open had
      // to fight its own background for the dots to be legible — the radial
      // well, the deepening, the alpha juggling — and all of that machinery is
      // what made it look busy. Nothing behind the mark but the room the app
      // is about to fill.
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = background.withValues(alpha: fieldAlpha),
      );
    }
    _stars(canvas, size, fieldAlpha);

    final (placements, unitSize, markAlpha) = _frame(size, openSize);
    if (markAlpha <= 0) return;
    OmiMarkPainter(
      placements: placements,
      color: ink,
      centre: _centre(size),
      unit: unitSize / OmiMarkGeometry.canvas,
      opacity: markAlpha,
    ).paint(canvas, size);
  }

  /// The anchor, but only when it is somewhere the user can actually see.
  ///
  /// The hub's mark lives at the top of a scrollable, so opening onto a chat
  /// with history reports it scrolled *above* the viewport — a negative y. Fly
  /// to that and the mark exits the top of the screen instead of handing over,
  /// which is worse than not having an anchor at all. Off-screen means fall
  /// back to the centred shrink.
  static Rect? reachableAnchor(Rect? handoff, Size size) {
    if (handoff == null || handoff.isEmpty) return null;
    return (Offset.zero & size).contains(handoff.center) ? handoff : null;
  }

  Rect? _reachable(Size size) => reachableAnchor(handoff, size);

  /// Where the mark is drawn this frame: the middle of the window until the
  /// settle beat, then travelling to the destination's mark on the same eased
  /// curve the shrink uses, so position and size arrive together.
  Offset _centre(Size size) {
    final middle = Offset(size.width / 2, size.height / 2);
    final target = _reachable(size)?.center;
    if (target == null || progress <= _settleEnd) return middle;
    return Offset.lerp(
      middle,
      target,
      Curves.easeInOutCubic.transform(_span(_settleEnd, 1)),
    )!;
  }

  /// The size the mark lands at. A reachable anchor is measured from the widget
  /// that is about to take over, so it beats the constant in every case.
  double _landingSize(Size size) =>
      _reachable(size)?.shortestSide ?? handoffSize;

  /// The field the mark arrives through: faint fixed points that fade up
  /// before the dots and hold until the handover. Positions come from a hash
  /// of the index rather than a generator, so the sky is the same sky every
  /// launch and the painter stays pure.
  void _stars(Canvas canvas, Size size, double fieldAlpha) {
    if (progress >= _settleEnd) return;
    // Up over the field beat, then held. Fixed, not twinkling: eighty points
    // each pulsing on their own sine was the single cheapest thing on screen,
    // and a sky does not flicker at one and a half hertz. They rise once and
    // hold, so the only thing moving in the frame is the mark.
    final rise = Curves.easeOutCubic.transform(
      (progress / _fieldEnd).clamp(0.0, 1.0),
    );
    final paint = Paint();
    final middle = Offset(size.width / 2, size.height / 2);
    for (var i = 0; i < _starCount; i++) {
      final hx = _hash(i * 2 + 1);
      final hy = _hash(i * 2 + 2);
      final at = Offset(hx * size.width, hy * size.height);
      // Clear of the mark, or they read as stray dots that failed to arrive.
      if ((at - middle).distance < size.shortestSide * 0.3) continue;
      // A wide spread of faint to very faint. An even field of identical dots
      // reads as noise; depth is what makes it read as distance.
      final depth = _hash(i * 2 + 3);
      final alpha = 0.30 * rise * fieldAlpha * (0.10 + 0.90 * depth * depth);
      canvas.drawCircle(
        at,
        (0.5 + 1.1 * depth) * (size.shortestSide / 420),
        paint..color = ink.withValues(alpha: alpha.clamp(0.0, 1.0)),
      );
    }
  }

  /// A cheap deterministic 0..1 from an integer.
  double _hash(int n) {
    final x = math.sin(n * 127.1 + 311.7) * 43758.5453;
    return x - x.floorToDouble();
  }

  /// This frame's dots, the size the mark is drawn at, and its overall opacity.
  (List<OmiDotPlacement>, double, double) _frame(Size size, double openSize) {
    if (progress <= _fieldEnd) {
      return (const <OmiDotPlacement>[], openSize, 0);
    }

    if (progress <= _convergeEnd) {
      // Just past the corners of the window, in the mark's own canvas units so
      // the entry scales with the screen. Any further out and the dots spend
      // the first third of the beat travelling somewhere nobody can see.
      final reach =
          size.longestSide * 0.62 / (openSize / OmiMarkGeometry.canvas);
      return (_converge(_span(_fieldEnd, _convergeEnd), reach), openSize, 1);
    }

    if (progress <= _showcaseEnd) {
      // One whole lap of the detuned Tusi couple. Both ends of the lap are the
      // mark — the lattice resynchronises exactly at turn 1 — so the blend in
      // and out only has to cover the stagger, not a jump.
      final lap = _span(_convergeEnd, _showcaseEnd);
      final blend = math.min(
        Curves.easeInOutCubic.transform((lap / 0.12).clamp(0.0, 1.0)),
        Curves.easeInOutCubic.transform(((1 - lap) / 0.14).clamp(0.0, 1.0)),
      );
      final rest = omiOrbPlacements(motion: OmiOrbMotion.mark, turn: lap);
      final show = omiOrbPlacements(
        motion: OmiOrbMotion.tusiPendulum,
        turn: lap,
      );
      return (_lerp(rest, show, blend), openSize, 1);
    }

    if (progress <= _settleEnd) {
      return (
        omiOrbPlacements(motion: OmiOrbMotion.mark, turn: 0),
        openSize,
        1,
      );
    }

    // Down to the size the next screen's mark will be, holding full opacity
    // most of the way so the shrink is the handover and not a dissolve.
    final out = _span(_settleEnd, 1);
    final eased = Curves.easeInOutCubic.transform(out);
    return (
      omiOrbPlacements(motion: OmiOrbMotion.mark, turn: 0),
      openSize + (_landingSize(size) - openSize) * eased,
      // Holds at full through the shrink, then clears completely over the last
      // tenth as the app's own mark takes over. Stopping short of zero leaves a
      // ghost sitting on the hub.
      1 - Curves.easeInCubic.transform(_span(0.90, 1)),
    );
  }

  /// Dots dropping in from the periphery: each is already at speed when it
  /// crosses the edge of the screen, curves inward and overshoots its rest
  /// radius before locking, one after another around the ring.
  List<OmiDotPlacement> _converge(double t, double reach) =>
      List<OmiDotPlacement>.generate(OmiMarkGeometry.dotCount, (i) {
        const stagger = 0.06;
        final local =
            ((t - i * stagger) / (1 - stagger * (OmiMarkGeometry.dotCount - 1)))
                .clamp(0.0, 1.0);
        final rest = OmiMarkGeometry.radiusOf(i);
        // No overshoot. easeOutBack made eight dots bounce past their radius
        // and spring back, which is the house style of every cheap splash
        // screen there has ever been. A long decelerating glide that simply
        // arrives is what reads as weight.
        final flight = Curves.easeOutQuint.transform(local);
        final glide = Curves.easeOutCubic.transform(local);
        return OmiDotPlacement(
          offset:
              OmiMarkGeometry.directionAt(
                OmiMarkGeometry.angleOf(i) + (1 - glide) * 0.55,
              ) *
              (reach + (rest - reach) * flight),
          scale: 0.55 + 0.45 * glide,
          alpha: (local * 5).clamp(0.0, 1.0),
        );
      }, growable: false);

  List<OmiDotPlacement> _lerp(
    List<OmiDotPlacement> a,
    List<OmiDotPlacement> b,
    double t,
  ) => List<OmiDotPlacement>.generate(
    OmiMarkGeometry.dotCount,
    (i) => OmiDotPlacement.lerp(a[i], b[i], t),
    growable: false,
  );

  /// [progress] rescaled to 0..1 across one beat.
  double _span(double from, double to) =>
      ((progress - from) / (to - from)).clamp(0.0, 1.0);

  @override
  bool shouldRepaint(OmiColdOpenPainter old) =>
      old.progress != progress ||
      old.background != background ||
      old.ink != ink ||
      old.handoffSize != handoffSize ||
      old.handoff != handoff;
}
