import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// The listening surface shown inside the omi window while a voice turn is
/// running: one large centred waveform driven by the combined microphone and
/// playback level, with the live transcript settling underneath it.
///
/// This is the in-app half of voice presentation only. When another
/// application is frontmost the window is not what the user is looking at, so
/// a separate native overlay takes over; this view stops animating rather
/// than drawing a second copy of the same thing behind it.
class InAppVoiceView extends StatefulWidget {
  const InAppVoiceView({
    required this.level,
    required this.userTranscript,
    required this.assistantTranscript,
    required this.onDone,
    this.notice,
    super.key,
  });

  /// Combined microphone/playback level, 0..1.
  final ValueListenable<double> level;

  /// What the user has said so far this turn.
  final ValueListenable<String> userTranscript;

  /// What the assistant has said back so far this turn.
  final ValueListenable<String> assistantTranscript;

  /// A one-line downgrade note (for example live voice falling back to plain
  /// transcription), shown under the transcript when present.
  final ValueListenable<String?>? notice;

  final VoidCallback onDone;

  @override
  State<InAppVoiceView> createState() => _InAppVoiceViewState();
}

class _InAppVoiceViewState extends State<InAppVoiceView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Ticker? _ticker;
  double _phase = 0;
  double _eased = 0;
  bool _frontmost = true;

  bool get _animated =>
      _frontmost && !MediaQuery.disableAnimationsOf(context) && !kIsWeb;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _frontmost =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused;
    widget.level.addListener(_levelChanged);
  }

  @override
  void didUpdateWidget(InAppVoiceView old) {
    super.didUpdateWidget(old);
    if (old.level != widget.level) {
      old.level.removeListener(_levelChanged);
      widget.level.addListener(_levelChanged);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only `resumed` means the omi window is the one in front. Anything else
    // and the native overlay is presenting instead, so the waveform here has
    // no viewer worth spending frames on.
    final frontmost = state == AppLifecycleState.resumed;
    if (frontmost == _frontmost) return;
    setState(() => _frontmost = frontmost);
    _syncTicker();
  }

  void _syncTicker() {
    if (_animated) {
      _ticker ??= createTicker(_tick)..start();
    } else {
      _ticker?.dispose();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.level.removeListener(_levelChanged);
    _ticker?.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    setState(() {
      _phase = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
      final target = widget.level.value.clamp(0.0, 1.0);
      // Fast attack, slow release, so speech snaps up and decays smoothly —
      // the same envelope the pill waveform uses, so the two read as one
      // instrument seen at different sizes.
      _eased = target > _eased
          ? _eased + (target - _eased) * 0.55
          : _eased + (target - _eased) * 0.12;
    });
  }

  void _levelChanged() {
    // The ticker consumes the level every frame; without one (reduced motion,
    // or the window sitting behind another app) rebuild from the raw level.
    if (_ticker == null && mounted) {
      setState(() => _eased = widget.level.value.clamp(0.0, 1.0));
    }
  }

  @override
  Widget build(BuildContext context) {
    final paper = _VoicePaper.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Listening',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: paper.muted,
                  letterSpacing: 1.6,
                ),
              ),
              const SizedBox(height: 28),
              LayoutBuilder(
                builder: (context, constraints) => SizedBox(
                  key: const Key('in_app_voice_waveform'),
                  width: constraints.maxWidth,
                  height: 168,
                  child: CustomPaint(
                    painter: InAppVoiceWaveformPainter(
                      level: _eased,
                      phase: _animated ? _phase : null,
                      color: paper.wave,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              _VoiceTranscript(
                userTranscript: widget.userTranscript,
                assistantTranscript: widget.assistantTranscript,
                paper: paper,
              ),
              if (widget.notice case final notice?) ...[
                const SizedBox(height: 16),
                ValueListenableBuilder<String?>(
                  valueListenable: notice,
                  builder: (context, value, _) => value == null
                      ? const SizedBox.shrink()
                      : Text(
                          value,
                          key: const Key('in_app_voice_notice'),
                          textAlign: TextAlign.center,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: paper.muted),
                        ),
                ),
              ],
              const SizedBox(height: 28),
              TextButton(
                key: const Key('stop_listening'),
                onPressed: widget.onDone,
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The transcript under the waveform: what the user said, then what the
/// assistant is saying back, both kept short enough to read at a glance.
class _VoiceTranscript extends StatelessWidget {
  const _VoiceTranscript({
    required this.userTranscript,
    required this.assistantTranscript,
    required this.paper,
  });

  final ValueListenable<String> userTranscript;
  final ValueListenable<String> assistantTranscript;
  final _VoicePaper paper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<String>(
      valueListenable: userTranscript,
      builder: (context, spoken, _) => ValueListenableBuilder<String>(
        valueListenable: assistantTranscript,
        builder: (context, reply, _) {
          final said = spoken.trim();
          final answered = reply.trim();
          if (said.isEmpty && answered.isEmpty) {
            return Text(
              'Say something',
              key: const Key('in_app_voice_transcript_idle'),
              style: theme.textTheme.bodyLarge?.copyWith(color: paper.muted),
            );
          }
          return Column(
            key: const Key('in_app_voice_transcript'),
            mainAxisSize: MainAxisSize.min,
            children: [
              if (said.isNotEmpty)
                Text(
                  said,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: paper.ink,
                    height: 1.35,
                  ),
                ),
              if (said.isNotEmpty && answered.isNotEmpty)
                const SizedBox(height: 18),
              if (answered.isNotEmpty)
                Text(
                  answered,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: paper.muted,
                    height: 1.4,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Warm-paper palette for the listening surface: cream and ink in light mode,
/// the same pair inverted in the dark theme.
class _VoicePaper {
  const _VoicePaper._({
    required this.ink,
    required this.muted,
    required this.wave,
  });

  final Color ink;
  final Color muted;
  final Color wave;

  static const _light = _VoicePaper._(
    ink: Color(0xff171716),
    muted: Color(0xff8d8980),
    wave: Color(0xff171716),
  );

  static const _dark = _VoicePaper._(
    ink: Color(0xfff4f2ea),
    muted: Color(0xffa6a49c),
    wave: Color(0xfffffcec),
  );

  static _VoicePaper of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;
}

/// A wide bar waveform: centre-weighted so the shape reads as a voice rather
/// than a level meter, riding a slow idle pulse so it breathes in silence.
class InAppVoiceWaveformPainter extends CustomPainter {
  InAppVoiceWaveformPainter({
    required this.level,
    required this.phase,
    required this.color,
  });

  static const barCount = 33;
  static const _barWidth = 5.0;
  static const _minimumHeight = 6.0;

  final double level;
  final double? phase;
  final Color color;

  /// Bar height multiplier: 1 at the centre, tapering to a quarter at the
  /// ends, so loud speech blooms out from the middle.
  static double profileAt(int index) {
    final centred = (index - (barCount - 1) / 2).abs() / ((barCount - 1) / 2);
    return 0.25 + 0.75 * math.cos(centred * math.pi / 2);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = _barWidth
      ..strokeCap = StrokeCap.round;
    final step = size.width / barCount;
    final reactive = math.pow(level.clamp(0.0, 1.0), 0.76).toDouble();
    final middle = size.height / 2;
    for (var index = 0; index < barCount; index++) {
      final x = step * index + step / 2;
      final idle = phase == null
          ? 0.0
          : (math.sin(phase! * 2.4 + index * 0.42) + 1) / 2 * 7;
      final height =
          _minimumHeight +
          idle +
          reactive * (size.height - _minimumHeight) * profileAt(index);
      final half = math.min(height, size.height) / 2;
      canvas.drawLine(
        Offset(x, middle - half),
        Offset(x, middle + half),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(InAppVoiceWaveformPainter old) =>
      old.level != level || old.phase != phase || old.color != color;
}
