import 'package:flutter/material.dart';

/// Wraps a vertical scrollable with page-coloured fades at its top and bottom
/// edges, each one hidden while the scroll view is already resting against
/// that edge. The colour defaults to the ambient scaffold background so the
/// fade reads as the page dissolving the content rather than as a scrim.
class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({
    required this.child,
    this.color,
    this.height = 24,
    super.key,
  });

  final Widget child;

  /// The opaque end of the gradient. Defaults to the scaffold background.
  final Color? color;

  /// How tall each fade is.
  final double height;

  @override
  State<ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  bool _topVisible = false;
  bool _bottomVisible = false;

  void _update(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return;
    final top = metrics.extentBefore > 1;
    final bottom = metrics.extentAfter > 1;
    if (top == _topVisible && bottom == _bottomVisible) return;
    if (!mounted) return;
    setState(() {
      _topVisible = top;
      _bottomVisible = bottom;
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).scaffoldBackgroundColor;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0) _update(notification.metrics);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth == 0) _update(notification.metrics);
          return false;
        },
        child: Stack(
          children: [
            widget.child,
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _EdgeFade(
                key: const Key('scroll_edge_fade_top'),
                color: color,
                height: widget.height,
                visible: _topVisible,
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _EdgeFade(
                key: const Key('scroll_edge_fade_bottom'),
                color: color,
                height: widget.height,
                visible: _bottomVisible,
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EdgeFade extends StatelessWidget {
  const _EdgeFade({
    required this.color,
    required this.height,
    required this.visible,
    required this.begin,
    required this.end,
    super.key,
  });

  final Color color;
  final double height;
  final bool visible;
  final Alignment begin;
  final Alignment end;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: begin,
              end: end,
              colors: [color, color.withValues(alpha: 0)],
            ),
          ),
        ),
      ),
    ),
  );
}
