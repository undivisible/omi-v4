import 'package:flutter_test/flutter_test.dart';
import 'package:omi/onboarding/onboarding_controller.dart';

void main() {
  test('introduction advances to real access setup', () {
    final controller = OnboardingController();
    addTearDown(controller.dispose);

    controller.continueFromIntroduction();

    expect(controller.stage, OnboardingStage.access);
  });

  test('access, scan, and profile answers advance in order', () {
    final controller = OnboardingController();
    addTearDown(controller.dispose);
    controller.continueFromIntroduction();
    controller.completeAccess();
    expect(controller.stage, OnboardingStage.scan);
    controller.completeScan();
    expect(controller.stage, OnboardingStage.profile);

    expect(controller.submitAnswer('   ', questionCount: 2), isFalse);
    expect(controller.questionIndex, 0);
    expect(controller.answers, isEmpty);

    expect(controller.submitAnswer('Alex', questionCount: 2), isTrue);
    expect(controller.questionIndex, 1);
    expect(controller.answers, ['Alex']);

    expect(
      controller.submitAnswer('Protect my focus', questionCount: 2),
      isTrue,
    );
    expect(controller.stage, OnboardingStage.use);
    expect(controller.answers, ['Alex', 'Protect my focus']);
  });
}
