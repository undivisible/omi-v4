import 'package:flutter_test/flutter_test.dart';
import 'package:omi/onboarding/onboarding_controller.dart';

void main() {
  test('introduction advances to real access setup', () {
    final controller = OnboardingController();
    addTearDown(controller.dispose);

    controller.continueFromIntroduction();

    expect(controller.stage, OnboardingStage.access);
  });

  test('access, scan, and profile advance in order automatically', () {
    final controller = OnboardingController();
    addTearDown(controller.dispose);
    controller.continueFromIntroduction();
    controller.completeAccess();
    expect(controller.stage, OnboardingStage.scan);
    controller.completeScan();
    expect(controller.stage, OnboardingStage.profile);

    controller.completeProfile();
    expect(controller.stage, OnboardingStage.use);
  });
}
