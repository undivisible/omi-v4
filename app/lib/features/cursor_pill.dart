import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cursor_pill_controller.dart';

const _pillInk = Color(0xff171716);
const _pillPaper = Color(0xfffffefa);
const _pillMuted = Color(0xff706e68);
const _pillGreen = Color(0xff2e8b57);
const _pillGreenSoft = Color(0x1a2e8b57);

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

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final listening = controller.state == CursorPillState.listening;
    return Focus(
      onKeyEvent: _handleKey,
      child: Column(
        key: const Key('cursor_pill'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!listening)
            for (final suggestion in controller.suggestions)
              _SuggestionRow(
                suggestion: suggestion,
                onTap: () => unawaited(controller.choose(suggestion)),
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

  Widget _pill(bool listening) => AnimatedContainer(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 160),
    curve: Curves.easeOut,
    height: 48,
    decoration: BoxDecoration(
      color: listening ? _pillGreenSoft : _pillPaper,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(
        color: listening ? _pillGreen : const Color(0x33171716),
        width: listening ? 1.6 : 1,
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x22000000),
          blurRadius: 18,
          offset: Offset(0, 6),
        ),
      ],
    ),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: listening
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
          ),
  );
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.suggestion, required this.onTap});

  final PillSuggestion suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Material(
      color: _pillPaper,
      shape: const StadiumBorder(side: BorderSide(color: Color(0x1a171716))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
