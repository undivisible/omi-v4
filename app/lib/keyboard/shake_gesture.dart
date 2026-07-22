// Mirrors the reference onboarding concept's mouse-shake-to-talk gesture
// (desktop/macos/design/omi-onboarding-concept/src/flow.ts): rapid pointer
// direction reversals fill a progress meter that starts voice at 100.

bool isShakeReversal(
  int previousDirection,
  int direction,
  int elapsedMilliseconds,
  double movement,
) =>
    movement.abs() >= 7 &&
    previousDirection != 0 &&
    direction != previousDirection &&
    elapsedMilliseconds < 260;

double advanceShakeProgress(double current, double movement) =>
    (current + movement.abs().clamp(0, 20)).clamp(0, 100).toDouble();
