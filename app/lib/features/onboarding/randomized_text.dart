import 'dart:math' as math;

import 'package:flutter/material.dart';

class RandomizedText extends StatefulWidget {
  const RandomizedText({
    required this.segments,
    required this.style,
    this.textAlign = TextAlign.start,
    super.key,
  });

  final List<(String, TextStyle?)> segments;
  final TextStyle style;
  final TextAlign textAlign;

  @override
  State<RandomizedText> createState() => _RandomizedTextState();
}

class _RandomizedTextState extends State<RandomizedText>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late final tokens = _tokens();

  List<({String text, TextStyle? style, double delay})> _tokens() {
    final random = math.Random();
    return [
      for (final segment in widget.segments)
        for (final match in RegExp(r'\s+|\S+').allMatches(segment.$1))
          (
            text: match.group(0)!,
            style: segment.$2,
            delay: match.group(0)!.trim().isEmpty
                ? 0
                : .05 + random.nextDouble() * .18,
          ),
    ];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      animation.value = 1;
    } else if (!animation.isAnimating && animation.value == 0) {
      animation.forward();
    }
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.segments.map((segment) => segment.$1).join(),
    child: ExcludeSemantics(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) => Text.rich(
          TextSpan(
            children: [
              for (final token in tokens)
                TextSpan(
                  text: token.text,
                  style: _style(token.style, token.delay),
                ),
            ],
          ),
          style: widget.style,
          textAlign: widget.textAlign,
        ),
      ),
    ),
  );

  TextStyle _style(TextStyle? tokenStyle, double delay) {
    final progress = ((animation.value - delay) / .62).clamp(0.0, 1.0);
    final opacity = Curves.easeOutExpo.transform(progress);
    final style = widget.style.merge(tokenStyle);
    final color = style.color ?? const Color(0xffffffff);
    return style.copyWith(color: color.withValues(alpha: color.a * opacity));
  }
}
