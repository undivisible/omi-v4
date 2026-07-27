import 'dart:async';

import 'package:flutter/material.dart';

import 'omi_orb.dart';

/// The mark, left alone.
///
/// Sit on a screen without touching it and after [settleAfter] the mark runs
/// *one* lap of *one* showcase motion, then returns to rest. After
/// [restBetween] it does it again, with the next motion in the rotation.
/// Any pointer or key event puts it straight back to rest.
///
/// One lap and home, rather than a rotation that runs until interrupted. A mark
/// that never stops moving is a mark you learn to ignore, and the two motions
/// do not share endpoints — cutting between them mid-performance is the jump
/// that made this read as the icon cycling through everything it knows.
///
/// This is the only place the long showcase motions are allowed to run on their
/// own. Everywhere else they have to be asked for, because a mark that performs
/// while you are trying to read is a mark that is in the way.
class OmiIdleShowcase extends StatefulWidget {
  const OmiIdleShowcase({
    this.size = 48,
    this.settleAfter = const Duration(seconds: 10),
    this.restBetween = const Duration(seconds: 30),
    this.lap = const Duration(milliseconds: 5200),
    this.color,
    this.reactive = true,
    this.state = OmiOrbState.idle,
    this.amplitude = 0,
    super.key,
  });

  final double size;

  /// What the app is doing right now. Anything other than idle wins outright:
  /// a mark performing a showcase lap while the assistant is thinking or
  /// listening is a mark that is not telling the truth about the app. The
  /// showcase is what it does when there is nothing to say.
  final OmiOrbState state;

  /// Input level, for [OmiOrbState.listening].
  final double amplitude;

  /// How long the screen has to be left alone before the mark stirs.
  ///
  /// Ten seconds is short enough that it reads as the mark noticing you have
  /// stopped, rather than as a screensaver.
  final Duration settleAfter;

  /// How long the mark rests between performances.
  ///
  /// Deliberately much longer than [settleAfter]: noticing you have gone quiet
  /// should be prompt, doing it again should not. This is the number that
  /// decides whether the idle reads as calm or as fidgeting.
  final Duration restBetween;

  /// How long one lap of a motion takes. The mark performs exactly one.
  final Duration lap;

  final Color? color;

  /// Whether the mark answers the pointer while it performs.
  final bool reactive;

  /// The rotation. One of these per performance, in order.
  ///
  /// Two, not six, and both of the quiet geometric ones. The variety in this
  /// app belongs to the working states — loading, thinking, searching each
  /// pick from their own set — because there the movement is telling you
  /// something. A mark performing at rest is just motion in your peripheral
  /// vision while you try to read.
  static const rotation = <OmiOrbMotion>[
    OmiOrbMotion.doubleCircle,
    OmiOrbMotion.tusi,
  ];

  @override
  State<OmiIdleShowcase> createState() => _OmiIdleShowcaseState();
}

class _OmiIdleShowcaseState extends State<OmiIdleShowcase> {
  Timer? _settle;
  Timer? _lap;

  /// Which motion the *next* performance uses. Advances after each lap so
  /// consecutive performances differ without ever cutting between motions
  /// mid-flight.
  int _next = 0;
  bool _stirring = false;

  /// Only performs when the app has nothing else for it to express.
  bool get _performing => _stirring && widget.state == OmiOrbState.idle;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(covariant OmiIdleShowcase old) {
    super.didUpdateWidget(old);
    // Work arriving is a reason to stop performing and a reason to restart the
    // clock, exactly like a pointer event.
    if (old.state != widget.state && widget.state != OmiOrbState.idle) _stir();
  }

  bool get _quiet =>
      debugOmiOrbStatic ||
      (MediaQuery.maybeOf(context)?.disableAnimations ?? false);

  void _arm([Duration? after]) {
    _settle?.cancel();
    _lap?.cancel();
    _settle = Timer(after ?? widget.settleAfter, _begin);
  }

  void _begin() {
    if (!mounted || _quiet) return;
    setState(() => _stirring = true);
    // One lap, then home. The orb's own crossfade carries it back to the mark,
    // so the end of the performance is a settle rather than a cut.
    _lap = Timer(widget.lap, () {
      if (!mounted) return;
      setState(() {
        _stirring = false;
        _next = (_next + 1) % OmiIdleShowcase.rotation.length;
      });
      _arm(widget.restBetween);
    });
  }

  /// Any sign of life stops the performance and restarts the clock.
  void _stir() {
    if (_stirring) {
      _lap?.cancel();
      setState(() => _stirring = false);
    }
    _arm();
  }

  @override
  void dispose() {
    _settle?.cancel();
    _lap?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_quiet) {
      return OmiActivityOrb(
        size: widget.size,
        color: widget.color,
        state: widget.state,
        amplitude: widget.amplitude,
      );
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _stir(),
      onPointerHover: (_) => _stir(),
      onPointerSignal: (_) => _stir(),
      child: OmiActivityOrb(
        size: widget.size,
        color: widget.color,
        reactive: widget.reactive,
        state: widget.state,
        amplitude: widget.amplitude,
        motion: _performing ? OmiIdleShowcase.rotation[_next] : null,
        period: _performing ? widget.lap : const Duration(seconds: 8),
      ),
    );
  }
}
