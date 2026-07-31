import 'package:flutter/material.dart';

/// Where the app's own mark sits on screen, in global coordinates.
///
/// The cold open and the hub each draw the same eight dots, and without this
/// they draw them in different places: the open finishes at the centre of the
/// window and the hub's mark lives above the greeting. Handing over between
/// those two positions is the jump that reads as two separate screens. The hub
/// publishes where its mark actually is, the open flies there, and the handover
/// becomes one object moving.
///
/// Null means nothing has reported yet — the destination has not been laid out.
/// Callers must treat that as "no anchor", never as a position.
class OmiMarkAnchor extends ValueNotifier<Rect?> {
  OmiMarkAnchor() : super(null);
}

/// Provides the [OmiMarkAnchor] to the subtree. Absent scope means nothing
/// publishes and nothing listens, which is the correct behaviour everywhere
/// except the one launch path that has both.
class OmiMarkAnchorScope extends InheritedWidget {
  const OmiMarkAnchorScope({
    required this.anchor,
    required super.child,
    super.key,
  });

  final OmiMarkAnchor anchor;

  static OmiMarkAnchor? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OmiMarkAnchorScope>()?.anchor;

  @override
  bool updateShouldNotify(OmiMarkAnchorScope old) => old.anchor != anchor;
}

/// Publishes its child's on-screen rect to the enclosing [OmiMarkAnchorScope].
///
/// Measurement happens after layout, so the first frame reports nothing. That
/// is fine: the open only reads the anchor once it starts settling, by which
/// point the destination has been laid out underneath it for most of a second.
class OmiMarkAnchorTarget extends StatefulWidget {
  const OmiMarkAnchorTarget({required this.child, super.key});

  final Widget child;

  @override
  State<OmiMarkAnchorTarget> createState() => _OmiMarkAnchorTargetState();
}

class _OmiMarkAnchorTargetState extends State<OmiMarkAnchorTarget> {
  OmiMarkAnchor? _anchor;
  Rect? _reported;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _anchor = OmiMarkAnchorScope.maybeOf(context);
    _schedule();
  }

  void _schedule() {
    if (_anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    final anchor = _anchor;
    if (!mounted || anchor == null) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect == _reported) return;
    _reported = rect;
    anchor.value = rect;
  }

  @override
  void dispose() {
    // A mark that has left the tree is not somewhere to fly to.
    final anchor = _anchor;
    final reported = _reported;
    if (anchor?.value == reported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (anchor?.value == reported) anchor?.value = null;
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    return widget.child;
  }
}
