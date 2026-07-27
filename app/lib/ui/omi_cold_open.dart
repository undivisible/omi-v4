import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'omi_orb.dart';
import 'omi_wa_palette.dart';

/// The cold open: the eight dots arrive from off the edges of the screen, lock
/// into the mark, run one lap of [OmiOrbMotion.tusiPendulum], then shrink to
/// the size the app's own mark is about to appear at and hand over.
///
/// It is the app-launch beat only. Nothing else in the product is allowed to
/// hold the user for three seconds, so nothing else uses it.
class OmiColdOpen extends StatefulWidget {
  const OmiColdOpen({
    required this.onDone,
    this.plate,
    this.background,
    this.color,
    this.handoffSize = 64,
    super.key,
  });

  /// Called once, when the mark has reached [handoffSize] and the field has
  /// faded off. Under reduce motion it is called on the first frame instead.
  final VoidCallback onDone;

  /// The field the dots arrive over. Defaults to Wada's plate 166 — Grenadine
  /// Pink falling through Naples Yellow into Deep Slate Green, the warm-to-cold
  /// run of a sunrise, which is what an app opening is.
  final OmiWaGradient? plate;

  /// Overrides [plate] with a flat colour. Defaults to the ambient theme, so
  /// the open does not flash a dark field over a light build on its way in.
  final Color? background;
  final Color? color;

  /// The size the mark leaves at — match it to the mark the next screen shows
  /// and the handover reads as one continuous object.
  final double handoffSize;

  /// Field, converge, lock, showcase, settle, hand off.
  static const Duration duration = Duration(milliseconds: 3260);

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
    return Semantics(
      label: 'Omi',
      child: GestureDetector(
        // Three seconds is a long time to hold someone who has already seen it.
        onTap: _finish,
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _clock,
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: OmiColdOpenPainter(
              progress: _clock.value,
              background: widget.background ?? theme.scaffoldBackgroundColor,
              plate: widget.background == null
                  ? (widget.plate ?? OmiWaPalette.dawn)
                  : null,
              ink: widget.color ?? theme.colorScheme.primary,
              handoffSize: widget.handoffSize,
            ),
          ),
        ),
      ),
    );
  }
}

/// The beats, as fractions of [OmiColdOpen.duration].
const double _fieldEnd = 0.02;
const double _convergeEnd = 0.30;
const double _showcaseEnd = 0.822;
const double _settleEnd = 0.914;

/// Draws one frame of the open. Public so a preview harness can step the
/// timeline without a ticker.
class OmiColdOpenPainter extends CustomPainter {
  const OmiColdOpenPainter({
    required this.progress,
    required this.background,
    required this.ink,
    required this.handoffSize,
    this.plate,
  });

  final double progress;
  final Color background;

  /// Painted over [background] when set. The dots read against the plate's
  /// dark end, which is why every plate in the palette finishes dark.
  final OmiWaGradient? plate;
  final Color ink;
  final double handoffSize;

  @override
  void paint(Canvas canvas, Size size) {
    final openSize = math.min(size.shortestSide * 0.46, 260.0);

    // The field goes out first and the mark second, so the last thing on screen
    // is the mark over the app rather than the mark over a black hole.
    final fieldAlpha = progress <= _settleEnd
        ? 1.0
        : 1 - Curves.easeOutCubic.transform(_span(_settleEnd, 1));
    if (fieldAlpha > 0) {
      final field = Offset.zero & size;
      canvas.drawRect(
        field,
        Paint()..color = background.withValues(alpha: fieldAlpha),
      );
      final wash = plate;
      if (wash != null) {
        canvas.drawRect(
          field,
          Paint()
            ..shader = wash.bokashi().createShader(field)
            ..color = const Color(0xffffffff).withValues(alpha: fieldAlpha),
        );
      }
    }

    final (placements, unitSize, markAlpha) = _frame(size, openSize);
    if (markAlpha <= 0) return;
    OmiMarkPainter(
      placements: placements,
      color: ink,
      centre: Offset(size.width / 2, size.height / 2),
      unit: unitSize / OmiMarkGeometry.canvas,
      opacity: markAlpha,
    ).paint(canvas, size);
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
      openSize + (handoffSize - openSize) * eased,
      1 - Curves.easeInCubic.transform(out) * 0.35,
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
        final flight = Curves.easeOutBack.transform(local);
        final glide = Curves.easeOutCubic.transform(local);
        return OmiDotPlacement(
          offset:
              OmiMarkGeometry.directionAt(
                OmiMarkGeometry.angleOf(i) + (1 - glide) * 0.9,
              ) *
              (reach + (rest - reach) * flight),
          scale: 0.32 + 0.68 * glide,
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
      old.plate != plate ||
      old.ink != ink ||
      old.handoffSize != handoffSize;
}
