import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../native/native_hub.dart' show ApprovalDecision;
import 'cursor_pill_controller.dart';
import 'cursor_pill_window.dart';

const _pillInk = Color(0xfffffefa);
const _pillMuted = Color(0xb3f4f2ec);
const _pillGreen = Color(0xff43c47e);

const pillHeight = 36.0;

/// The blur/material itself is rendered natively (NSGlassEffectView on
/// macOS 26+, NSVisualEffectView otherwise) below the transparent Flutter
/// view; this widget only paints a thin specular border and soft shadow —
/// no fills, tints, or gradients of its own.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    required this.child,
    this.radius = pillHeight / 2,
    super.key,
  });

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(color: const Color(0x47ffffff)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - 1),
        child: child,
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
  final _chipKeys = <GlobalKey>[];
  String _lastGlassSignature = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _text.addListener(_textChanged);
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

  void _textChanged() {
    widget.controller.inputChanged(_text.text);
    _changed();
  }

  void _focusChanged() {
    if (!mounted) return;
    // Rebuild so the typing shimmer starts/stops with focus.
    setState(() {});
    if (_focus.hasFocus) return;
    if (widget.controller.state == CursorPillState.input) {
      unawaited(widget.controller.dismiss());
    }
  }

  /// The dimmed inline continuation after the caret: a static suggestion
  /// whose label extends the typed text is the instant first tier; when none
  /// matches, the debounced AI prediction from the controller fills in.
  String? get _ghostRemainder {
    final typed = _text.text;
    if (typed.isEmpty) return null;
    for (final suggestion in widget.controller.suggestions) {
      if (suggestion.label.toLowerCase().startsWith(typed.toLowerCase()) &&
          suggestion.label.length > typed.length) {
        return suggestion.label.substring(typed.length);
      }
    }
    return widget.controller.predictedRemainder(typed);
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
      unawaited(widget.controller.dismissSurface());
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
    for (final key in _chipKeys) {
      final rect = _rectOf(key);
      if (rect != null) {
        regions.add((
          x: rect.left,
          y: rect.top,
          w: rect.width,
          h: rect.height,
          r: rect.height / 2,
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
    if (controller.state == CursorPillState.hidden) {
      if (_lastGlassSignature.isNotEmpty) {
        _lastGlassSignature = '';
        unawaited(CursorPillWindow.updateGlass(const []));
      }
      return const SizedBox.shrink();
    }
    final listening = controller.state == CursorPillState.listening;
    final working = controller.state == CursorPillState.working;
    final chipCount = listening || working ? 0 : controller.suggestions.length;
    while (_chipKeys.length > chipCount) {
      _chipKeys.removeLast();
    }
    while (_chipKeys.length < chipCount) {
      _chipKeys.add(GlobalKey());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportGlassRegions());
    if (listening) return _voice();
    if (working) return _working();
    return Focus(
      onKeyEvent: _handleKey,
      child: Column(
        key: const Key('cursor_pill'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (controller.suggestions.isNotEmpty) ...[
            Column(
              key: const Key('cursor_pill_chips'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, suggestion)
                    in controller.suggestions.indexed) ...[
                  if (index > 0) const SizedBox(height: 6),
                  KeyedSubtree(
                    key: _chipKeys[index],
                    child: _ChipEntrance(
                      index: index,
                      child: _SuggestionChip(
                        suggestion: suggestion,
                        onTap: () => unawaited(controller.choose(suggestion)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
          ],
          _pill(),
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

  /// Live voice: no pill, just the clicky waveform inside a soft warm glow
  /// (a subtle, steady-state cousin of the shake-complete burst). The whole
  /// surface spans the screen: an entry burst sweeps to the edges and settles
  /// into a glow hugging the screen borders, with the waveform centered.
  Widget _voice() => SizedBox.expand(
    key: const Key('cursor_pill'),
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: ListeningEdgeGlow(
            key: const Key('cursor_pill_edge_glow'),
            level: widget.controller.level,
            animated: !MediaQuery.disableAnimationsOf(context),
          ),
        ),
        SizedBox(
          key: const Key('cursor_pill_listening'),
          width: 96,
          height: 72,
          child: Stack(
            alignment: Alignment.center,
            children: [
              ListeningGlow(
                level: widget.controller.level,
                animated: !MediaQuery.disableAnimationsOf(context),
              ),
              PillWaveform(
                key: const Key('cursor_pill_waveform'),
                level: widget.controller.level,
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 48,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.controller.notice case final notice?)
                Text(
                  notice,
                  key: const Key('cursor_pill_notice'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: _pillMuted),
                ),
              if (widget.controller.error case final message?)
                Text(
                  message,
                  key: const Key('cursor_pill_error'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xffb3261e),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  /// While the agent works (or a deterministic launch flashes), the pill
  /// swaps its input for a live status line; a pending action proposal
  /// renders above it with one-click approve/dismiss controls.
  Widget _working() => Column(
    key: const Key('cursor_pill'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.controller.proposal case final proposal?) ...[
        LiquidGlass(
          radius: 13,
          child: Padding(
            key: const Key('cursor_pill_proposal'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  proposal.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _pillInk,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Text(
                    proposal.summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _pillMuted, fontSize: 12),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      key: const Key('cursor_pill_approve'),
                      onPressed: () => unawaited(
                        widget.controller.decideProposal(
                          ApprovalDecision.approveOnce,
                        ),
                      ),
                      child: const Text(
                        'Approve',
                        style: TextStyle(color: _pillGreen, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      key: const Key('cursor_pill_deny'),
                      onPressed: () => unawaited(
                        widget.controller.decideProposal(
                          ApprovalDecision.reject,
                        ),
                      ),
                      child: const Text(
                        'Dismiss',
                        style: TextStyle(color: _pillMuted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
      LiquidGlass(
        key: _pillKey,
        child: SizedBox(
          height: pillHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 26,
                  height: 20,
                  child: PillWaveform(level: widget.controller.level),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: Text(
                    widget.controller.status ?? 'Working on it…',
                    key: const Key('cursor_pill_status'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _pillInk, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  Widget _pill() => LiquidGlass(
    key: _pillKey,
    child: AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      height: pillHeight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Stack(
        children: [
          _pillContent(),
          Positioned.fill(
            child: IgnorePointer(
              child: TypingShimmer(
                enabled:
                    _focus.hasFocus && !MediaQuery.disableAnimationsOf(context),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _pillContent() => Row(
    children: [
      Expanded(
        child: Stack(
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
              cursorColor: _pillInk,
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
      ),
      const SizedBox(width: 6),
      IconButton(
        key: const Key('cursor_pill_mic'),
        tooltip: 'Talk instead',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 26, height: 26),
        iconSize: 16,
        color: _pillMuted,
        icon: const Icon(Icons.mic_none_rounded),
        onPressed: () => unawaited(widget.controller.beginVoice()),
      ),
    ],
  );
}

/// Animates a suggestion chip into view: a quick fade/rise plus a single
/// diagonal gradient shimmer sweeping across the chip, staggered ~80ms per
/// chip. With animations disabled the chip appears instantly, no sweep.
class _ChipEntrance extends StatefulWidget {
  const _ChipEntrance({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_ChipEntrance> createState() => _ChipEntranceState();
}

class _ChipEntranceState extends State<_ChipEntrance>
    with SingleTickerProviderStateMixin {
  static const _staggerMs = 80;
  static const _sweepMs = 420;

  AnimationController? _controller;
  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    if (MediaQuery.disableAnimationsOf(context)) return;
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.index * _staggerMs + _sweepMs),
    )..forward();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return widget.child;
    final total = widget.index * _staggerMs + _sweepMs;
    final entrance = CurvedAnimation(
      parent: controller,
      curve: Interval(
        widget.index * _staggerMs / total,
        1,
        curve: Curves.easeOutCubic,
      ),
    );
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final t = entrance.value;
        if (t >= 1) return child!;
        final sweep = -0.35 + t * 1.7;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 6),
            child: ShaderMask(
              blendMode: BlendMode.srcATop,
              shaderCallback: (bounds) => LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: const [
                  Color(0x00ffffff),
                  Color(0x59ffffff),
                  Color(0x00ffffff),
                ],
                stops: [
                  (sweep - 0.35).clamp(0.0, 1.0),
                  sweep.clamp(0.0, 1.0),
                  (sweep + 0.35).clamp(0.0, 1.0),
                ],
              ).createShader(bounds),
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.suggestion, required this.onTap});

  final PillSuggestion suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => LiquidGlass(
    radius: 13,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                suggestion.link == null
                    ? Icons.bolt_rounded
                    : Icons.mail_outline_rounded,
                size: 13,
                color: _pillMuted,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text(
                  suggestion.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _pillInk,
                    fontSize: 12,
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

/// Five slim, center-weighted bars next to the mic — the clicky look. The
/// bars ride a gentle idle pulse so the waveform visibly breathes even in
/// silence, and stretch with the live audio level while the user speaks.
class PillWaveform extends StatefulWidget {
  const PillWaveform({required this.level, this.color = _pillGreen, super.key});

  static const barProfile = [0.55, 0.8, 1.0, 0.8, 0.55];

  final ValueListenable<double> level;
  final Color color;

  @override
  State<PillWaveform> createState() => _PillWaveformState();
}

class _PillWaveformState extends State<PillWaveform>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  double _phase = 0;
  double _eased = 0;

  bool get _animated => !MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_levelChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_animated) {
      _ticker ??= createTicker(_tick)..start();
    } else {
      _ticker?.dispose();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    widget.level.removeListener(_levelChanged);
    _ticker?.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    setState(() {
      _phase = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
      final target = widget.level.value.clamp(0.0, 1.0);
      // Fast attack, slow release, so speech snaps up and decays smoothly.
      _eased = target > _eased
          ? _eased + (target - _eased) * 0.55
          : _eased + (target - _eased) * 0.12;
    });
  }

  void _levelChanged() {
    // The ticker consumes the level every frame; without a ticker (reduced
    // motion), rebuild directly from the latest level.
    if (_ticker == null && mounted) {
      setState(() => _eased = widget.level.value.clamp(0.0, 1.0));
    }
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(26, 20),
    painter: PillWaveformPainter(
      level: _eased,
      phase: _animated ? _phase : null,
      color: widget.color,
    ),
  );
}

class PillWaveformPainter extends CustomPainter {
  PillWaveformPainter({required this.level, required this.phase, this.color});

  static const _barWidth = 2.5;
  final double level;
  final double? phase;
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    final profile = PillWaveform.barProfile;
    final paint = Paint()
      ..color = color ?? _pillGreen
      ..strokeWidth = _barWidth
      ..strokeCap = StrokeCap.round;
    final step = size.width / profile.length;
    final reactive = math.pow(level.clamp(0.0, 1.0), 0.76).toDouble();
    for (var i = 0; i < profile.length; i++) {
      final x = step * i + step / 2;
      final idle = phase == null
          ? 0.0
          : (math.sin(phase! * 3.6 + i * 0.35) + 1) / 2 * 1.5;
      final height = 3 + idle + reactive * (size.height - 5) * profile[i];
      final half = math.min(height, size.height) / 2;
      canvas.drawLine(
        Offset(x, size.height / 2 - half),
        Offset(x, size.height / 2 + half),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(PillWaveformPainter old) =>
      old.level != level || old.phase != phase || old.color != color;
}

/// The warm listening glow behind the waveform — the same web-demo treatment
/// as the shake glow (blue core bleeding into peach), held at a subtle,
/// steady intensity that swells gently with the live audio level. With
/// animations disabled it renders a still glow with no breathing pulse.
class ListeningGlow extends StatefulWidget {
  const ListeningGlow({required this.level, required this.animated, super.key});

  final ValueListenable<double> level;
  final bool animated;

  @override
  State<ListeningGlow> createState() => _ListeningGlowState();
}

class _ListeningGlowState extends State<ListeningGlow>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  double _phase = 0;

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant ListeningGlow old) {
    super.didUpdateWidget(old);
    _syncTicker();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  void _syncTicker() {
    if (widget.animated) {
      _ticker ??= createTicker((elapsed) {
        setState(
          () =>
              _phase = elapsed.inMicroseconds / Duration.microsecondsPerSecond,
        );
      })..start();
    } else {
      _ticker?.dispose();
      _ticker = null;
    }
  }

  void _changed() {
    if (_ticker == null && mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.level.removeListener(_changed);
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final level = widget.level.value.clamp(0.0, 1.0);
    final breathe = widget.animated ? (math.sin(_phase * 2.2) + 1) / 2 : 0.5;
    final intensity = (0.28 + level * 0.5 + breathe * 0.12).clamp(0.0, 0.9);
    final scale = 0.82 + level * 0.5 + breathe * 0.06;
    return IgnorePointer(
      child: Transform.scale(
        scale: scale,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                const Color(0xff96c4ff).withValues(alpha: intensity),
                Color.lerp(
                  const Color(0xfff2c2ac),
                  const Color(0x00f2c2ac),
                  0.45,
                )!.withValues(alpha: intensity * 0.6),
                const Color(0x00f2c2ac),
              ],
              stops: const [0.0, 0.42, 0.72],
            ),
          ),
        ),
      ),
    );
  }
}

/// The full-screen listening treatment: an entry burst that sweeps from the
/// center past the screen edges (the shake-complete burst, writ large), then
/// a steady glow hugging all four screen edges — the same blue-into-peach
/// palette as [ListeningGlow] — swelling gently with the live audio level.
/// With animations disabled it renders the settled edge glow with no burst
/// and no breathing pulse.
class ListeningEdgeGlow extends StatefulWidget {
  const ListeningEdgeGlow({
    required this.level,
    required this.animated,
    super.key,
  });

  static const burstDuration = Duration(milliseconds: 720);

  final ValueListenable<double> level;
  final bool animated;

  @override
  State<ListeningEdgeGlow> createState() => _ListeningEdgeGlowState();
}

class _ListeningEdgeGlowState extends State<ListeningEdgeGlow>
    with TickerProviderStateMixin {
  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: ListeningEdgeGlow.burstDuration,
  );
  Ticker? _ticker;
  double _phase = 0;

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant ListeningEdgeGlow old) {
    super.didUpdateWidget(old);
    _syncMotion();
  }

  void _syncMotion() {
    if (widget.animated) {
      if (!_burst.isAnimating && !_burst.isCompleted) _burst.forward();
      _ticker ??= createTicker((elapsed) {
        setState(
          () =>
              _phase = elapsed.inMicroseconds / Duration.microsecondsPerSecond,
        );
      })..start();
    } else {
      _burst.value = 1;
      _ticker?.dispose();
      _ticker = null;
    }
  }

  void _changed() {
    if (_ticker == null && mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.level.removeListener(_changed);
    _burst.dispose();
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final level = widget.level.value.clamp(0.0, 1.0);
    final breathe = widget.animated ? (math.sin(_phase * 2.2) + 1) / 2 : 0.5;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _burst,
        builder: (context, _) => CustomPaint(
          painter: ListeningEdgeGlowPainter(
            level: level,
            breathe: breathe,
            burst: Curves.easeOutCubic.transform(_burst.value),
          ),
        ),
      ),
    );
  }
}

class ListeningEdgeGlowPainter extends CustomPainter {
  ListeningEdgeGlowPainter({
    required this.level,
    required this.breathe,
    required this.burst,
  });

  static const core = Color(0xff96c4ff);
  static const warm = Color(0xfff2c2ac);

  final double level;
  final double breathe;
  final double burst;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bounds = Offset.zero & size;
    if (burst < 1) {
      final radius =
          (0.25 + burst * 1.05) * size.longestSide * 0.75 +
          size.shortestSide * 0.1;
      final opacity = (1 - burst) * 0.8;
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            core.withValues(alpha: opacity),
            warm.withValues(alpha: opacity * 0.6),
            warm.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.42, 0.72],
        ).createShader(Rect.fromCircle(center: bounds.center, radius: radius));
      canvas.drawRect(bounds, paint);
    }
    final settled = burst.clamp(0.0, 1.0);
    final intensity =
        (0.22 + level * 0.5 + breathe * 0.1).clamp(0.0, 0.85) * settled;
    if (intensity <= 0) return;
    final thickness =
        size.shortestSide * (0.16 + level * 0.08 + breathe * 0.02);
    void edge(Rect rect, Alignment begin, Alignment end) {
      final paint = Paint()
        ..shader = LinearGradient(
          begin: begin,
          end: end,
          colors: [
            core.withValues(alpha: intensity),
            warm.withValues(alpha: intensity * 0.4),
            warm.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(rect);
      canvas.drawRect(rect, paint);
    }

    edge(
      Rect.fromLTWH(0, 0, size.width, thickness),
      Alignment.topCenter,
      Alignment.bottomCenter,
    );
    edge(
      Rect.fromLTWH(0, size.height - thickness, size.width, thickness),
      Alignment.bottomCenter,
      Alignment.topCenter,
    );
    edge(
      Rect.fromLTWH(0, 0, thickness, size.height),
      Alignment.centerLeft,
      Alignment.centerRight,
    );
    edge(
      Rect.fromLTWH(size.width - thickness, 0, thickness, size.height),
      Alignment.centerRight,
      Alignment.centerLeft,
    );
  }

  @override
  bool shouldRepaint(ListeningEdgeGlowPainter old) =>
      old.level != level || old.breathe != breathe || old.burst != burst;
}

/// A slow diagonal light sweep looping across the input glass while it holds
/// focus — the typing shimmer. Rendered as a non-interactive overlay (it takes
/// no child) so it never intercepts text entry. Honors reduced motion via
/// [enabled]: when off it paints nothing.
class TypingShimmer extends StatefulWidget {
  const TypingShimmer({required this.enabled, super.key});

  static const period = Duration(milliseconds: 2200);

  final bool enabled;

  @override
  State<TypingShimmer> createState() => _TypingShimmerState();
}

class _TypingShimmerState extends State<TypingShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: TypingShimmer.period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant TypingShimmer old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.enabled) {
      if (!_sweep.isAnimating) _sweep.repeat();
    } else {
      _sweep.stop();
      _sweep.value = 0;
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _sweep,
      builder: (context, child) {
        final travel = -0.4 + 1.8 * _sweep.value;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [
                Color(0x00fffefa),
                Color(0x33fffefa),
                Color(0x00fffefa),
              ],
              stops: [
                (travel - 0.22).clamp(0.0, 1.0),
                travel.clamp(0.0, 1.0),
                (travel + 0.22).clamp(0.0, 1.0),
              ],
            ),
          ),
        );
      },
    );
  }
}
