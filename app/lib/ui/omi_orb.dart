import 'package:flutter/material.dart';

/// Holds the mark still under `flutter test`. A perpetual rotation never lets
/// `pumpAndSettle` return, so every widget test that settles a screen holding
/// the mark would hang; `test/flutter_test_config.dart` flips this true. In
/// production it stays false and the mark always turns.
bool debugOmiOrbStatic = false;

/// The omi mark — the ring of dots from the brand logo — always turning. It is
/// the greeter avatar, the assistant's chat profile picture, and (spun faster)
/// the loading indicator, so the same identity carries every waiting state.
class OmiActivityOrb extends StatefulWidget {
  const OmiActivityOrb({
    this.size = 46,
    this.period = const Duration(seconds: 8),
    super.key,
  });

  /// The loading cadence: the same mark, spun fast enough to read as activity.
  const OmiActivityOrb.loading({double size = 46, Key? key})
    : this(size: size, period: const Duration(milliseconds: 1100), key: key);

  final double size;

  /// One full rotation takes this long. The idle greeter turns slowly; the
  /// loading constructor turns it fast.
  final Duration period;

  @override
  State<OmiActivityOrb> createState() => _OmiActivityOrbState();
}

class _OmiActivityOrbState extends State<OmiActivityOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: widget.period,
  );

  @override
  void didUpdateWidget(covariant OmiActivityOrb old) {
    super.didUpdateWidget(old);
    if (old.period != widget.period) {
      _spin.duration = widget.period;
      if (_spin.isAnimating) _spin.repeat();
    }
  }

  bool get _reduceMotion =>
      debugOmiOrbStatic ||
      (MediaQuery.maybeOf(context)?.disableAnimations ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honour the platform "reduce motion" setting: a mark that never stops
    // spinning is exactly what that setting exists to quiet.
    if (_reduceMotion) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      _spin.repeat();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Omi',
    child: RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: RotationTransition(
          turns: _spin,
          child: Image.asset(
            'assets/images/omi_logo.png',
            width: widget.size,
            height: widget.size,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    ),
  );
}
