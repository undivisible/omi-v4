import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'omi_wa_palette.dart';

/// The app's glass, in one place.
///
/// Every surface goes through here rather than reaching for the package
/// directly, so "what glass looks like in Omi" stays one decision. It is
/// deliberately quiet: the mark and the type are the loud things, and glass
/// that announces itself competes with both.
///
/// [AdaptiveGlass] is used rather than the raw renderer because that one is
/// Impeller-only and renders *nothing* on Skia and web — and this app ships a
/// web portal and a web demo.
enum OmiGlassTone {
  /// Chrome that floats over content: tab bars, the settings button.
  chrome,

  /// Cards and sheets that hold content.
  panel,
}

class OmiGlass extends StatelessWidget {
  const OmiGlass({
    required this.child,
    this.tone = OmiGlassTone.panel,
    this.radius = 22,
    this.interactive = false,
    super.key,
  });

  final Widget child;
  final OmiGlassTone tone;
  final double radius;

  /// Whether the surface should respond to touch with the package's own
  /// pinch-and-settle. On for things that are pressed, off for backdrops.
  final bool interactive;

  /// Warm enough to belong with the cream, cold enough to read as glass.
  static const _warmTint = Color(0x14fffcec);
  static const _coolTint = Color(0x0e97acc8);

  LiquidGlassSettings get _settings => switch (tone) {
    OmiGlassTone.chrome => const LiquidGlassSettings(
      glassColor: _warmTint,
      thickness: 12,
      blur: 8,
      chromaticAberration: 0.006,
      lightIntensity: 0.35,
      refractiveIndex: 1.15,
      saturation: 1.15,
      glowIntensity: 0.35,
    ),
    OmiGlassTone.panel => const LiquidGlassSettings(
      glassColor: _coolTint,
      thickness: 18,
      blur: 12,
      chromaticAberration: 0.01,
      lightIntensity: 0.45,
      refractiveIndex: 1.2,
      saturation: 1.25,
      glowIntensity: 0.5,
    ),
  };

  @override
  Widget build(BuildContext context) => AdaptiveGlass(
    shape: LiquidRoundedSuperellipse(borderRadius: radius),
    settings: _settings,
    isInteractive: interactive,
    child: child,
  );
}

/// A Wada plate as a page backdrop: the plate's colours held far enough back
/// that they read as weather behind the content rather than as the content.
///
/// This is what makes the platforms match — mobile pages, the desktop hub and
/// the cold open all take their ground from the same six plates.
class OmiWaBackdrop extends StatelessWidget {
  const OmiWaBackdrop({
    required this.gradient,
    required this.child,
    this.opacity = 0.16,
    super.key,
  });

  final OmiWaGradient gradient;
  final Widget child;

  /// How much of the plate shows through. Past about a fifth the gradient
  /// starts competing with body type for attention.
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      // Dark surfaces already carry contrast, so the plate is pulled further
      // back there or the page turns into a poster.
      decoration: BoxDecoration(
        gradient: gradient.veil(opacity: dark ? opacity * 0.7 : opacity),
      ),
      child: child,
    );
  }
}
