import 'package:flutter_test/flutter_test.dart';
import 'package:omi/ui/omi_orb.dart';

void main() {
  group('OmiThinkingPulse', () {
    test('matches site keyframe endpoints', () {
      expect(OmiThinkingPulse.at(0), (0.62, 1.0));
      expect(OmiThinkingPulse.at(0.12).$1, closeTo(1.0, 0.001));
      expect(OmiThinkingPulse.at(0.12).$2, closeTo(1.14, 0.001));
      expect(OmiThinkingPulse.at(0.70), (0.62, 1.0));
      expect(OmiThinkingPulse.at(0.99), (0.62, 1.0));
    });

    test('staggers peaks around the ring', () {
      const turn = 0.12;
      final peaks = List.generate(OmiMarkGeometry.dotCount, (i) {
        final pulse = OmiThinkingPulse.at(OmiThinkingPulse.localPhase(i, turn));
        return pulse.$1;
      });
      expect(peaks.indexOf(peaks.reduce((a, b) => a > b ? a : b)), 0);
    });
  });
}
