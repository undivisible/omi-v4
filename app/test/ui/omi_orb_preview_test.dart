import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/ui/omi_cold_open.dart';
import 'package:omi/ui/omi_orb.dart';

/// Renders the motion catalog and the cold open to PNG contact sheets, so the
/// choreography can be looked at rather than reasoned about. Inert unless a
/// directory is named:
///
///     OMI_ORB_SHEET=/tmp/omi flutter test test/ui/omi_orb_preview_test.dart
final _sheetDir = Platform.environment['OMI_ORB_SHEET'];
const _cell = 120.0;
const _cols = 8;
const _ink = Color(0xfffffcec);
const _field = Color(0xff24201e);

Future<void> _write(
  WidgetTester tester,
  ui.Picture picture,
  Size size,
  String name,
) => tester.runAsync(() async {
  final image = await picture.toImage(size.width.round(), size.height.round());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File('$_sheetDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
});

void main() {
  testWidgets('every motion, eight frames across the lap', (tester) async {
    final rows = OmiOrbMotion.values.length;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = Size(_cell * _cols, _cell * rows);
    canvas.drawRect(Offset.zero & size, Paint()..color = _field);

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < _cols; c++) {
        final turn = c / _cols;
        OmiMarkPainter(
          placements: omiOrbPlacements(
            motion: OmiOrbMotion.values[r],
            turn: turn,
            level: 0.8,
            burst: turn,
          ),
          color: _ink,
          centre: Offset(_cell * (c + 0.5), _cell * (r + 0.5)),
          unit: _cell * 0.78 / OmiMarkGeometry.canvas,
        ).paint(canvas, size);
      }
    }

    await _write(tester, recorder.endRecording(), size, 'motions');
  }, skip: _sheetDir == null);

  testWidgets('the cold open, beat by beat', (tester) async {
    const frames = 16;
    const w = 220.0;
    const h = 300.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = Size(w * 8, h * 2);

    for (var i = 0; i < frames; i++) {
      canvas.save();
      canvas.translate(w * (i % 8), h * (i ~/ 8));
      canvas.clipRect(const Rect.fromLTWH(0, 0, w, h));
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, w, h),
        Paint()..color = const Color(0xff000000),
      );
      OmiColdOpenPainter(
        progress: i / (frames - 1),
        background: _field,
        ink: _ink,
        handoffSize: 64,
      ).paint(canvas, const Size(w, h));
      canvas.restore();
    }

    await _write(tester, recorder.endRecording(), size, 'cold_open');
  }, skip: _sheetDir == null);
}
