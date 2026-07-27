import 'dart:async';

import 'package:flutter/material.dart';

import 'omi_orb.dart';

/// The mark, left alone.
///
/// Sit on a screen without touching it and after [settleAfter] the mark starts
/// working through the showcase motions — a lap each, one after another, with
/// the crossfade carrying it between them. Any pointer or key event puts it
/// straight back to rest.
///
/// This is the only place the long showcase motions are allowed to run on their
/// own. Everywhere else they have to be asked for, because a mark that performs
/// while you are trying to read is a mark that is in the way.
class OmiIdleShowcase extends StatefulWidget {
  const OmiIdleShowcase({
    this.size = 48,
    this.settleAfter = const Duration(seconds: 14),
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

  /// How long the screen has to be left alone before the mark starts.
  final Duration settleAfter;

  /// How long each motion is held.
  final Duration lap;

  final Color? color;

  /// Whether the mark answers the pointer while it performs.
  final bool reactive;

  /// The rotation, in order. Each is a motion that reads at a glance and
  /// returns cleanly to the mark, so the sequence never looks like it broke.
  static const rotation = <OmiOrbMotion>[
    OmiOrbMotion.doubleCircle,
    OmiOrbMotion.tusi,
    OmiOrbMotion.pendulumWave,
    OmiOrbMotion.nestedOrbit,
    OmiOrbMotion.tusiPendulum,
    OmiOrbMotion.gather,
  ];

  @override
  State<OmiIdleShowcase> createState() => _OmiIdleShowcaseState();
}

class _OmiIdleShowcaseState extends State<OmiIdleShowcase> {
  Timer? _settle;
  Timer? _advance;
  int _step = -1;

  /// Only performs when the app has nothing else for it to express.
  bool get _performing => _step >= 0 && widget.state == OmiOrbState.idle;

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

  void _arm() {
    _settle?.cancel();
    _advance?.cancel();
    _settle = Timer(widget.settleAfter, _begin);
  }

  void _begin() {
    if (!mounted || _quiet) return;
    setState(() => _step = 0);
    _advance = Timer.periodic(widget.lap, (_) {
      if (!mounted) return;
      setState(() => _step = (_step + 1) % OmiIdleShowcase.rotation.length);
    });
  }

  /// Any sign of life stops the performance and restarts the clock.
  void _stir() {
    if (_performing) {
      _advance?.cancel();
      setState(() => _step = -1);
    }
    _arm();
  }

  @override
  void dispose() {
    _settle?.cancel();
    _advance?.cancel();
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
        motion: _performing ? OmiIdleShowcase.rotation[_step] : null,
        period: _performing ? widget.lap : const Duration(seconds: 8),
      ),
    );
  }
}
