import 'package:flutter/material.dart';

/// Gradients taken from Sanzo Wada's 配色事典 (*A Dictionary of Color
/// Combinations*, 1933–34).
///
/// Wada published 348 plates of two-, three- and four-colour combinations. The
/// six here are real plates, quoted in his order and at his values — the point
/// is that the colours were chosen to sit together by someone who spent a
/// career on the question, so a gradient between them holds up where an
/// invented pair goes muddy in the middle.
///
/// Values come from the CMYK-to-sRGB conversion of the plates published at
/// `github.com/mattdesl/dictionary-of-colour-combinations`. Wada printed in
/// ink, so these are a reading of the plates, not a colorimetric match to a
/// 1933 press.
@immutable
class OmiWaGradient {
  const OmiWaGradient({
    required this.plate,
    required this.name,
    required this.stops,
    required this.names,
  });

  /// The plate number in the 配色事典, so any of these can be looked up.
  final int plate;

  /// What this gradient is for, in the app's terms.
  final String name;

  /// Wada's colours, in his order.
  final List<Color> stops;

  /// His names for them, in the same order.
  final List<String> names;

  /// A bokashi (ぼかし) fade — the smooth graded wash of a woodblock print, with
  /// no hard stop between colours. [begin] and [end] default to a vertical run,
  /// which is how the technique is nearly always cut.
  LinearGradient bokashi({
    AlignmentGeometry begin = Alignment.topCenter,
    AlignmentGeometry end = Alignment.bottomCenter,
  }) => LinearGradient(begin: begin, end: end, colors: stops);

  /// The same colours as a soft wash behind content: held to [opacity] so type
  /// stays the loudest thing on the page.
  LinearGradient veil({
    double opacity = 0.18,
    AlignmentGeometry begin = Alignment.topLeft,
    AlignmentGeometry end = Alignment.bottomRight,
  }) => LinearGradient(
    begin: begin,
    end: end,
    colors: [for (final color in stops) color.withValues(alpha: opacity)],
  );

  /// The same plate pulled toward its own dark end by [amount], 0 to 1.
  ///
  /// Wada printed on paper, so his plates run bright. A screen at night wants
  /// the same hues with the lights down, and lerping toward the plate's own
  /// darkest colour keeps the hue relationships he chose instead of flattening
  /// everything toward grey.
  OmiWaGradient deepened(double amount) {
    final t = amount.clamp(0.0, 1.0);
    final floor = stops.last;
    return OmiWaGradient(
      plate: plate,
      name: name,
      stops: [for (final c in stops) Color.lerp(c, floor, t)!],
      names: names,
    );
  }

  /// The colour to sit type in when this gradient is behind it.
  Color get ink =>
      ThemeData.estimateBrightnessForColor(stops.last) == Brightness.dark
      ? const Color(0xfffffcec)
      : const Color(0xff171716);
}

/// The plates this app draws on.
@immutable
class OmiWaPalette {
  const OmiWaPalette._();

  /// Grenadine Pink falling through Naples Yellow into Deep Slate Green. The
  /// warm-to-cold run of a sunrise, which is what the cold open is.
  static const dawn = OmiWaGradient(
    plate: 166,
    name: 'dawn',
    stops: [Color(0xfff48067), Color(0xfffbe6a0), Color(0xff112f2c)],
    names: ['Grenadine Pink', 'Naples Yellow', 'Deep Slate Green'],
  );

  /// Ivory Buff through English Red into Black.
  static const ember = OmiWaGradient(
    plate: 190,
    name: 'ember',
    stops: [Color(0xffebd3a2), Color(0xffd96629), Color(0xff111314)],
    names: ['Ivory Buff', 'English Red', 'Black'],
  );

  /// Salvia Blue through Neutral Gray into Deep Indigo — the quietest of the
  /// six, and the one that carries small type best.
  static const indigo = OmiWaGradient(
    plate: 139,
    name: 'indigo',
    stops: [Color(0xff97acc8), Color(0xffb6bfc1), Color(0xff051230)],
    names: ['Salvia Blue', 'Neutral Gray', 'Deep Indigo'],
  );

  /// Sudan Brown over Glaucous Green into Black.
  static const moss = OmiWaGradient(
    plate: 207,
    name: 'moss',
    stops: [Color(0xffa36752), Color(0xffb4cdc2), Color(0xff111314)],
    names: ['Sudan Brown', 'Glaucous Green', 'Black'],
  );

  /// Carmine over Pinkish Cinnamon into Deep Indigo. The loudest; keep it for
  /// moments that have earned it.
  static const lacquer = OmiWaGradient(
    plate: 232,
    name: 'lacquer',
    stops: [Color(0xffcc1236), Color(0xffeeb480), Color(0xff051230)],
    names: ['Carmine', 'Pinkish Cinnamon', 'Deep Indigo'],
  );

  /// Sulpher Yellow through Yellow Orange into Vandar Poel's Blue.
  static const harbour = OmiWaGradient(
    plate: 151,
    name: 'harbour',
    stops: [Color(0xfff5ecc2), Color(0xfff99d1b), Color(0xff064f6e)],
    names: ['Sulpher Yellow', 'Yellow Orange', "Vandar Poel's Blue"],
  );

  static const all = <OmiWaGradient>[
    dawn,
    ember,
    indigo,
    moss,
    lacquer,
    harbour,
  ];

  static OmiWaGradient byPlate(int plate) =>
      all.firstWhere((g) => g.plate == plate);
}
