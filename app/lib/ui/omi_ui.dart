import 'package:flutter/material.dart';

import 'omi_typography.dart';

export 'omi_orb.dart';
export 'omi_typography.dart';
export 'scroll_edge_fade.dart';

enum OmiButtonVariant { primary, secondary, destructive }

class OmiButton extends StatelessWidget {
  const OmiButton({
    required this.onPressed,
    required this.child,
    this.variant = OmiButtonVariant.primary,
    super.key,
  });

  static const _cream = Color(0xfffffcec);
  static const _ink = Color(0xff171716);
  static const _red = Color(0xffb42318);

  final VoidCallback? onPressed;
  final Widget child;
  final OmiButtonVariant variant;

  static const _textStyle = TextStyle(
    fontFamily: OmiFonts.sans,
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );

  @override
  Widget build(BuildContext context) => switch (variant) {
    OmiButtonVariant.primary => FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        backgroundColor: _cream,
        foregroundColor: _ink,
        shape: const StadiumBorder(),
        textStyle: _textStyle,
      ),
      child: child,
    ),
    OmiButtonVariant.secondary => OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        foregroundColor: _cream,
        side: const BorderSide(color: Color(0x8cfffcec)),
        shape: const StadiumBorder(),
        textStyle: _textStyle,
      ),
      child: child,
    ),
    OmiButtonVariant.destructive => FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        backgroundColor: _red,
        foregroundColor: _cream,
        shape: const StadiumBorder(),
        textStyle: _textStyle,
      ),
      child: child,
    ),
  };
}
