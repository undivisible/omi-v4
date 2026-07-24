import 'package:flutter_test/flutter_test.dart';
import 'package:omi/keyboard/shake_gesture.dart';

void main() {
  test('a fast reversal within the window counts as a shake', () {
    expect(isShakeReversal(1, -1, 100, 30), isTrue);
  });

  test('a slow reversal outside the window does not count', () {
    expect(isShakeReversal(1, -1, 400, 30), isFalse);
  });

  test('a small movement does not count even if reversed quickly', () {
    expect(isShakeReversal(1, -1, 100, 3), isFalse);
  });

  test('the first movement has no prior direction to reverse from', () {
    expect(isShakeReversal(0, 1, 100, 30), isFalse);
  });

  test('progress accumulates and caps at 100', () {
    expect(advanceShakeProgress(0, 30), 30);
    expect(advanceShakeProgress(0, 40), 34);
    expect(advanceShakeProgress(90, 30), 100);
    expect(advanceShakeProgress(100, 30), 100);
  });
}
