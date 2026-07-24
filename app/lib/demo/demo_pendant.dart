import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Mirrors the pendant firmware's LED semantics, the same two states the
/// mobile companion mirrors: blue while connected and idle, red while
/// capturing. The charging states (green) are not shown because charging is
/// not surfaced over BLE.
const _stateBlue = Color(0xff4a8fdd);
const _stateRed = Color(0xffd9564a);

/// A drawn pendant.
///
/// There is no Bluetooth in a browser and there is no device paired to this
/// page, so nothing here is a reading from hardware — it is a simulation, and
/// it says so twice: once in the banner over the illustration and once beside
/// every number. What it is for is showing what the physical product does:
/// the LED states, the capture toggle those states follow, and the battery
/// the real device reports over BLE.
class DemoPendantScreen extends StatefulWidget {
  const DemoPendantScreen({super.key});

  @override
  State<DemoPendantScreen> createState() => _DemoPendantScreenState();
}

class _DemoPendantScreenState extends State<DemoPendantScreen>
    with SingleTickerProviderStateMixin {
  bool _capturing = false;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  /// The ripples run only when motion is wanted. Under `prefers-reduced-motion`
  /// the controller never starts, so there is no repaint loop at all.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xfff4f2ea) : const Color(0xff171716);
    final muted = dark ? const Color(0xffa6a49c) : const Color(0xff706e68);
    final paper = dark ? const Color(0xff171716) : const Color(0xfff7f6f1);
    final hairline = dark ? const Color(0x1ffffcec) : const Color(0x14171716);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final narrow = MediaQuery.sizeOf(context).width < 560;
    return Scaffold(
      backgroundColor: paper,
      appBar: AppBar(
        backgroundColor: paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: ink,
        title: Text(
          'The pendant',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Notice(ink: ink, muted: muted, hairline: hairline),
                  const SizedBox(height: 20),
                  AspectRatio(
                    aspectRatio: 1.35,
                    child: RepaintBoundary(
                      child: AnimatedBuilder(
                        animation: _pulse,
                        builder: (context, _) => CustomPaint(
                          painter: _PendantPainter(
                            capturing: _capturing,
                            phase: reduceMotion ? 0.35 : _pulse.value,
                            animate: !reduceMotion,
                            ink: ink,
                            muted: muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _Row(
                    label: 'Simulated capture',
                    value: _capturing
                        ? 'Capturing — LED red'
                        : 'Idle, connected — LED blue',
                    ink: ink,
                    muted: muted,
                    hairline: hairline,
                    trailing: Switch(
                      key: const Key('demo_pendant_capture'),
                      value: _capturing,
                      onChanged: (value) => setState(() => _capturing = value),
                    ),
                  ),
                  _Row(
                    label: 'Battery',
                    value: '78% (simulated)',
                    ink: ink,
                    muted: muted,
                    hairline: hairline,
                  ),
                  _Row(
                    label: 'Link',
                    value: 'Bluetooth LE to your phone (simulated)',
                    ink: ink,
                    muted: muted,
                    hairline: hairline,
                  ),
                  _Row(
                    label: 'Board',
                    value: 'nRF5340, CV1 firmware image',
                    ink: ink,
                    muted: muted,
                    hairline: hairline,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'The real pendant streams audio over Bluetooth LE to the '
                    'phone, which relays bounded chunks to the hub. Final '
                    'transcript segments become evidence, and the LED follows '
                    'the app\'s capture state so the state is legible from '
                    'across the room. Pairing one needs the app and a radio, '
                    'neither of which a web page has.',
                    style: TextStyle(fontSize: 13, height: 1.55, color: muted),
                  ),
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.ink,
    required this.muted,
    required this.hairline,
  });

  final Color ink;
  final Color muted;
  final Color hairline;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      border: Border.all(color: hairline),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline_rounded, size: 15, color: muted),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            'Simulation. No device is paired — a browser has no Bluetooth '
            'radio to pair one with. The states below are the real firmware\'s '
            'states, drawn.',
            style: TextStyle(fontSize: 12, height: 1.45, color: muted),
          ),
        ),
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    required this.ink,
    required this.muted,
    required this.hairline,
    this.trailing,
  });

  final String label;
  final String value;
  final Color ink;
  final Color muted;
  final Color hairline;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: hairline)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: muted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 13, height: 1.4, color: ink),
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );
}

/// Draws the pendant: body, lanyard loop, microphone port, LED, and the
/// Bluetooth ripples leaving it. The ripples are the only motion, and they
/// stop entirely under reduced motion.
class _PendantPainter extends CustomPainter {
  const _PendantPainter({
    required this.capturing,
    required this.phase,
    required this.animate,
    required this.ink,
    required this.muted,
  });

  final bool capturing;
  final double phase;
  final bool animate;
  final Color ink;
  final Color muted;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.42, size.height * 0.54);
    final radius = math.min(size.width, size.height) * 0.22;
    final led = capturing ? _stateRed : _stateBlue;

    for (var i = 0; i < 3; i++) {
      final travel = ((phase + i / 3) % 1.0);
      final ripple = radius * (1.35 + travel * 2.4);
      final fade = (1 - travel) * (animate ? 0.34 : 0.22);
      canvas.drawCircle(
        center,
        ripple,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = led.withValues(alpha: fade.clamp(0, 1)),
      );
    }

    final loop = Offset(center.dx, center.dy - radius * 1.28);
    canvas.drawCircle(
      loop,
      radius * 0.3,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.12
        ..color = muted.withValues(alpha: 0.75),
    );

    final body = Rect.fromCircle(center: center, radius: radius);
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, Radius.circular(radius * 0.42)),
      Paint()..color = ink.withValues(alpha: 0.92),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        body.deflate(radius * 0.08),
        Radius.circular(radius * 0.36),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.14),
    );

    final port = Offset(center.dx, center.dy + radius * 0.42);
    for (var i = -1; i <= 1; i++) {
      canvas.drawCircle(
        Offset(port.dx + i * radius * 0.17, port.dy),
        radius * 0.045,
        Paint()..color = Colors.white.withValues(alpha: 0.3),
      );
    }

    final ledCenter = Offset(center.dx, center.dy - radius * 0.34);
    canvas.drawCircle(
      ledCenter,
      radius * 0.28,
      Paint()
        ..color = led.withValues(alpha: 0.28)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.22),
    );
    canvas.drawCircle(ledCenter, radius * 0.12, Paint()..color = led);

    final label = TextPainter(
      text: TextSpan(
        text: capturing ? 'capturing' : 'idle, connected',
        style: TextStyle(
          fontSize: math.max(10, radius * 0.2),
          letterSpacing: 0.4,
          fontWeight: FontWeight.w600,
          color: led,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(
      canvas,
      Offset(center.dx + radius * 1.9, center.dy - label.height / 2),
    );
  }

  @override
  bool shouldRepaint(_PendantPainter old) =>
      old.capturing != capturing || old.phase != phase || old.ink != ink;
}
