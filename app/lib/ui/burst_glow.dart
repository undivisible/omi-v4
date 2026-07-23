import 'package:flutter/material.dart';

/// The warm radial glow from the cursor-shake finale: it grows with
/// [progress] and, once [complete] flips true, bursts outward (scale ~4.8)
/// while fading over [burstDuration] before signalling [onBurstDone].
///
/// Sizes itself, so callers place it by wrapping it — a `Positioned` with a
/// half-size `FractionalTranslation` anchors it on a point, a `Stack` centres
/// it on a widget.
class OmiBurstGlow extends StatefulWidget {
  const OmiBurstGlow({
    required this.progress,
    required this.complete,
    this.onBurstDone,
    this.baseDiameter = 120,
    this.growth = 360,
    super.key,
  });

  /// How full the glow is, 0…1.
  final double progress;

  /// Once true the glow bursts exactly once.
  final bool complete;

  final VoidCallback? onBurstDone;

  /// Diameter at zero progress, and how much progress adds to it.
  final double baseDiameter;
  final double growth;

  static const burstDuration = Duration(milliseconds: 720);

  @override
  State<OmiBurstGlow> createState() => _OmiBurstGlowState();
}

class _OmiBurstGlowState extends State<OmiBurstGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: OmiBurstGlow.burstDuration,
  );
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _burst.addStatusListener((status) {
      if (status == AnimationStatus.completed) _finish();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Deliberately not initState: deciding whether to burst reads the reduced
    // motion preference, and a glow can be handed to us already complete.
    if (widget.complete) _maybeBurst();
  }

  @override
  void didUpdateWidget(covariant OmiBurstGlow old) {
    super.didUpdateWidget(old);
    if (widget.complete) _maybeBurst();
  }

  void _finish() {
    if (_fired) return;
    _fired = true;
    widget.onBurstDone?.call();
  }

  void _maybeBurst() {
    if (_burst.isAnimating || _burst.isCompleted) return;
    // Reduced motion keeps the finale honest without moving anything: the
    // burst is skipped and whatever it gates happens straight away.
    if (MediaQuery.disableAnimationsOf(context)) {
      _finish();
      return;
    }
    _burst.forward();
  }

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.baseDiameter + widget.progress * widget.growth;
    return AnimatedBuilder(
      animation: _burst,
      builder: (context, child) {
        // cubic-bezier(0.16, 1, 0.3, 1) easing → strong ease-out.
        final t = Curves.easeOutCubic.transform(_burst.value);
        final scale = widget.complete
            ? 0.7 + widget.progress * 0.3 + t * 4.1
            : 1.0;
        final opacity =
            (widget.complete ? (1 - t) : 1.0) * (widget.progress * 0.84);
        return IgnorePointer(
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: SizedBox.square(dimension: base * scale, child: child),
          ),
        );
      },
      child: const DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [Color(0xff96c4ff), Color(0xfff2c2ac), Color(0x00f2c2ac)],
            stops: [0.0, 0.42, 0.72],
          ),
        ),
      ),
    );
  }
}
