import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cursor_pill_controller.dart';
import 'cursor_pill_window.dart';

const _pillInk = Color(0xfffffefa);
const _pillMuted = Color(0xb3f4f2ec);
const _pillGreen = Color(0xff43c47e);

const pillHeight = 36.0;

/// The blur/material itself is rendered natively (NSGlassEffectView on
/// macOS 26+, NSVisualEffectView otherwise) below the transparent Flutter
/// view; this widget only paints the specular border and, when listening,
/// a faint tint wash over transparent content.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    required this.child,
    this.radius = pillHeight / 2,
    this.tint,
    super.key,
  });

  final Widget child;
  final double radius;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x8cffffff), Color(0x1affffff), Color(0x4dffffff)],
          stops: [0, 0.55, 1],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius - 1),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tint?.withValues(alpha: 0.14) ?? Colors.transparent,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class CursorPill extends StatefulWidget {
  const CursorPill({
    required this.controller,
    this.autofocus = true,
    super.key,
  });

  final CursorPillController controller;
  final bool autofocus;

  @override
  State<CursorPill> createState() => _CursorPillState();
}

class _CursorPillState extends State<CursorPill> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _pillKey = GlobalKey();
  final _rowKeys = <GlobalKey>[];
  String _lastGlassSignature = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _text.addListener(_changed);
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _focusChanged() {
    if (_focus.hasFocus || !mounted) return;
    if (widget.controller.state == CursorPillState.input) {
      unawaited(widget.controller.dismiss());
    }
  }

  String? get _ghostRemainder {
    final typed = _text.text;
    if (typed.isEmpty) return null;
    for (final suggestion in widget.controller.suggestions) {
      if (suggestion.label.toLowerCase().startsWith(typed.toLowerCase()) &&
          suggestion.label.length > typed.length) {
        return suggestion.label.substring(typed.length);
      }
    }
    return null;
  }

  void _acceptGhost() {
    final remainder = _ghostRemainder;
    if (remainder == null) return;
    final value = _text.text + remainder;
    _text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      unawaited(widget.controller.dismiss());
      return KeyEventResult.handled;
    }
    if (_ghostRemainder != null &&
        (event.logicalKey == LogicalKeyboardKey.tab ||
            event.logicalKey == LogicalKeyboardKey.arrowRight)) {
      _acceptGhost();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static Rect? _rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final origin = box.localToGlobal(Offset.zero);
    return origin & box.size;
  }

  /// Reports the rounded-rect frames of the glass surfaces to the native
  /// layer after each frame, so the real Liquid Glass mask tracks layout.
  void _reportGlassRegions() {
    if (!mounted) return;
    final regions = <({double x, double y, double w, double h, double r})>[];
    for (final key in _rowKeys) {
      final rect = _rectOf(key);
      if (rect != null) {
        regions.add((
          x: rect.left,
          y: rect.top,
          w: rect.width,
          h: rect.height,
          r: 14,
        ));
      }
    }
    final pillRect = _rectOf(_pillKey);
    if (pillRect != null) {
      regions.add((
        x: pillRect.left,
        y: pillRect.top,
        w: pillRect.width,
        h: pillRect.height,
        r: pillHeight / 2,
      ));
    }
    final signature = regions
        .map(
          (region) =>
              '${region.x.round()},${region.y.round()},'
              '${region.w.round()},${region.h.round()},${region.r}',
        )
        .join(';');
    if (signature == _lastGlassSignature) return;
    _lastGlassSignature = signature;
    unawaited(CursorPillWindow.updateGlass(regions));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final listening = controller.state == CursorPillState.listening;
    final rowCount = listening ? 0 : controller.suggestions.length;
    while (_rowKeys.length > rowCount) {
      _rowKeys.removeLast();
    }
    while (_rowKeys.length < rowCount) {
      _rowKeys.add(GlobalKey());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportGlassRegions());
    return Focus(
      onKeyEvent: _handleKey,
      child: Column(
        key: const Key('cursor_pill'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!listening)
            for (final (index, suggestion) in controller.suggestions.indexed)
              KeyedSubtree(
                key: _rowKeys[index],
                child: _SuggestionRow(
                  suggestion: suggestion,
                  onTap: () => unawaited(controller.choose(suggestion)),
                ),
              ),
          if (controller.suggestions.isNotEmpty && !listening)
            const SizedBox(height: 6),
          _pill(listening),
          if (controller.error case final message?) ...[
            const SizedBox(height: 6),
            Text(
              message,
              key: const Key('cursor_pill_error'),
              style: const TextStyle(fontSize: 12, color: Color(0xffb3261e)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pill(bool listening) => LiquidGlass(
    key: _pillKey,
    tint: listening ? _pillGreen : null,
    child: AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      height: pillHeight - 2,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: _pillContent(listening),
    ),
  );

  Widget _pillContent(bool listening) => listening
      ? Row(
          key: const Key('cursor_pill_listening'),
          children: [
            const Icon(Icons.mic_rounded, size: 18, color: _pillGreen),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Listening…',
                style: TextStyle(
                  color: _pillGreen,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            PillWaveform(
              key: const Key('cursor_pill_waveform'),
              level: widget.controller.level,
            ),
          ],
        )
      : Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (_ghostRemainder case final remainder?)
              IgnorePointer(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: _text.text,
                        style: const TextStyle(color: Colors.transparent),
                      ),
                      TextSpan(
                        text: remainder,
                        style: const TextStyle(color: _pillMuted),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            TextField(
              key: const Key('cursor_pill_input'),
              controller: _text,
              focusNode: _focus,
              autofocus: widget.autofocus,
              maxLines: 1,
              style: const TextStyle(color: _pillInk, fontSize: 14),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                hintText: 'Ask me anything…',
                hintStyle: TextStyle(color: _pillMuted, fontSize: 14),
              ),
              onSubmitted: (value) =>
                  unawaited(widget.controller.submit(value)),
            ),
          ],
        );
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.suggestion, required this.onTap});

  final PillSuggestion suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: LiquidGlass(
      radius: 14,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(
                  suggestion.link == null
                      ? Icons.bolt_rounded
                      : Icons.mail_outline_rounded,
                  size: 15,
                  color: _pillMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    suggestion.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _pillInk,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class PillWaveform extends StatefulWidget {
  const PillWaveform({
    required this.level,
    this.color = _pillGreen,
    this.bars = 9,
    super.key,
  });

  final ValueListenable<double> level;
  final Color color;
  final int bars;

  @override
  State<PillWaveform> createState() => _PillWaveformState();
}

class _PillWaveformState extends State<PillWaveform> {
  late final List<double> _history = List.filled(widget.bars, 0);

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_levelChanged);
  }

  @override
  void dispose() {
    widget.level.removeListener(_levelChanged);
    super.dispose();
  }

  void _levelChanged() {
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < _history.length - 1; i++) {
        _history[i] = _history[i + 1];
      }
      _history[_history.length - 1] = widget.level.value.clamp(0, 1);
    });
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(52, 22),
    painter: _WaveformPainter(List.of(_history), widget.color),
  );
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.levels, this.color);

  final List<double> levels;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final step = size.width / levels.length;
    for (var i = 0; i < levels.length; i++) {
      final x = step * i + step / 2;
      final half = math.max(1.5, levels[i] * size.height / 2);
      canvas.drawLine(
        Offset(x, size.height / 2 - half),
        Offset(x, size.height / 2 + half),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      !listEquals(old.levels, levels) || old.color != color;
}
