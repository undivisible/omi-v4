// Mirrors the reference onboarding concept's mouse-shake-to-talk gesture
// (desktop/macos/design/omi-onboarding-concept/src/flow.ts): rapid pointer
// direction reversals fill a progress meter that starts voice at 100.

// The min travel, reversal window and gain below set how hard the shake is.
// They are loosened calibration values kept in sync with the native detector
// in macos/Runner/MainFlutterWindow.swift; the old ones needed a frantic
// 5–7 reversals to fire.
bool isShakeReversal(
  int previousDirection,
  int direction,
  int elapsedMilliseconds,
  double movement,
) =>
    movement.abs() >= 4 &&
    previousDirection != 0 &&
    direction != previousDirection &&
    elapsedMilliseconds < 320;

double advanceShakeProgress(double current, double movement) =>
    (current + movement.abs().clamp(0, 34)).clamp(0, 100).toDouble();
