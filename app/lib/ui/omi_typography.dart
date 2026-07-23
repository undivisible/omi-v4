import 'package:flutter/material.dart';

/// The three faces the product ships. Inter carries every structural run of
/// text; the Geist faces are accents only and never body copy.
class OmiFonts {
  const OmiFonts._();

  static const sans = 'Inter';
  static const mono = 'Geist Mono';
  static const pixel = 'Geist Pixel';
}

/// Named accent styles for the Geist faces. Reach for these instead of writing
/// `TextStyle(fontFamily: ...)` inline.
class OmiAccentText {
  const OmiAccentText._();

  /// Kickers and eyebrows above a heading.
  static const eyebrow = TextStyle(
    fontFamily: OmiFonts.pixel,
    fontSize: 12,
    height: 1.2,
    letterSpacing: 1.6,
  );

  /// Section labels and small caps set in the pixel face.
  static const sectionLabel = TextStyle(
    fontFamily: OmiFonts.pixel,
    fontSize: 11,
    height: 1.2,
    letterSpacing: 2,
  );

  /// Field labels and other short structural markers.
  static const label = TextStyle(
    fontFamily: OmiFonts.mono,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.25,
    letterSpacing: .6,
  );

  /// Tabular numerals, counters and durations.
  static const numeric = TextStyle(
    fontFamily: OmiFonts.mono,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.2,
  );

  /// Technical text: ids, endpoints, keys, code.
  static const mono = TextStyle(
    fontFamily: OmiFonts.mono,
    fontSize: 13,
    height: 1.35,
  );

  /// The same, one step down, for dense inline identifiers.
  static const monoSmall = TextStyle(
    fontFamily: OmiFonts.mono,
    fontSize: 11,
    height: 1.3,
    letterSpacing: .2,
  );
}

/// The app-wide text theme. Every [MaterialApp] in the product builds its
/// [ThemeData] from this so desktop, mobile and web share one typographic
/// system in both brightnesses.
const omiTextTheme = TextTheme(
  displaySmall: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -1),
  headlineMedium: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -.5),
  titleMedium: TextStyle(fontWeight: FontWeight.w600),
  bodyLarge: TextStyle(height: 1.45),
);
