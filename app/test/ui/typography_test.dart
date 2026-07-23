import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/ui/omi_typography.dart';

/// The `flutter: fonts:` block of pubspec.yaml, as {family: [assets]}.
Map<String, List<String>> _declaredFonts() {
  final lines = File('pubspec.yaml').readAsLinesSync();
  final declared = <String, List<String>>{};
  var inFonts = false;
  String? family;
  for (final line in lines) {
    if (line == '  fonts:') {
      inFonts = true;
      continue;
    }
    if (!inFonts) continue;
    if (line.isNotEmpty && !line.startsWith('  ')) break;
    final familyMatch = RegExp(r'^    - family: (.+)$').firstMatch(line);
    if (familyMatch != null) {
      family = familyMatch.group(1)!;
      declared[family] = [];
      continue;
    }
    final asset = RegExp(r'^        - asset: (.+)$').firstMatch(line);
    if (asset != null && family != null) declared[family]!.add(asset.group(1)!);
  }
  return declared;
}

void main() {
  final declared = _declaredFonts();

  test('the three faces are declared with the weights the app uses', () {
    expect(declared[OmiFonts.sans], hasLength(4));
    expect(declared[OmiFonts.mono], hasLength(2));
    expect(declared[OmiFonts.pixel], hasLength(1));
  });

  testWidgets('every declared font file exists and parses as a real font', (
    tester,
  ) async {
    for (final family in [OmiFonts.sans, OmiFonts.mono, OmiFonts.pixel]) {
      final assets = declared[family];
      expect(assets, isNotNull, reason: '$family is not declared in pubspec');
      for (final asset in assets!) {
        final file = File(asset);
        expect(
          file.existsSync(),
          isTrue,
          reason: '$asset is declared but missing on disk',
        );
        final loader = FontLoader(family)
          ..addFont(Future.value(file.readAsBytesSync().buffer.asByteData()));
        await loader.load();
      }
    }
  });

  testWidgets('text rendered with an accent style keeps the Geist face', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: OmiFonts.sans, textTheme: omiTextTheme),
        home: Scaffold(
          body: Column(
            children: [
              const Text('body copy'),
              Text('ENDPOINT', style: OmiAccentText.sectionLabel),
              Text('req_01H8', style: OmiAccentText.mono),
            ],
          ),
        ),
      ),
    );
    RenderParagraph paragraphOf(String text) =>
        tester.renderObject<RenderParagraph>(find.text(text));
    expect(paragraphOf('body copy').text.style?.fontFamily, OmiFonts.sans);
    expect(paragraphOf('ENDPOINT').text.style?.fontFamily, OmiFonts.pixel);
    expect(paragraphOf('req_01H8').text.style?.fontFamily, OmiFonts.mono);
  });

  testWidgets('the bundled Inter is really used, not a silent fallback', (
    tester,
  ) async {
    final bytes = File(
      declared[OmiFonts.sans]!.first,
    ).readAsBytesSync().buffer.asByteData();
    await (FontLoader(OmiFonts.sans)..addFont(Future.value(bytes))).load();
    Size measure(String? family) {
      final painter = TextPainter(
        text: TextSpan(
          text: 'Typography',
          style: TextStyle(fontFamily: family, fontSize: 32),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      return painter.size;
    }

    // The test harness's fallback face is a fixed-advance placeholder, so a
    // width that matches it means the real font never loaded.
    expect(measure(OmiFonts.sans).width, isNot(measure('NoSuchFamily').width));
  });

  test('accent styles use the Geist faces, never Inter', () {
    expect(OmiAccentText.eyebrow.fontFamily, OmiFonts.pixel);
    expect(OmiAccentText.sectionLabel.fontFamily, OmiFonts.pixel);
    expect(OmiAccentText.label.fontFamily, OmiFonts.mono);
    expect(OmiAccentText.numeric.fontFamily, OmiFonts.mono);
    expect(OmiAccentText.mono.fontFamily, OmiFonts.mono);
    expect(OmiAccentText.monoSmall.fontFamily, OmiFonts.mono);
  });
}
