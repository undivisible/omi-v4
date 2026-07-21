import 'package:flutter_test/flutter_test.dart';
import 'package:omi/onboarding/onboarding_controller.dart';

void main() {
  test('preview acknowledgement is required before profile questions', () {
    final controller = OnboardingController();
    addTearDown(controller.dispose);

    controller.continueFromIntroduction();

    expect(controller.stage, OnboardingStage.introduction);
    expect(controller.validationMessage, isNotNull);

    controller.setPreviewAcknowledged(true);
    controller.continueFromIntroduction();

    expect(controller.stage, OnboardingStage.profile);
  });

  test('answers are validated and remain volatile controller state', () {
    final controller = OnboardingController();
    addTearDown(controller.dispose);
    controller.setPreviewAcknowledged(true);
    controller.continueFromIntroduction();

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
    expect(controller.stage, OnboardingStage.permissions);
    expect(controller.answers, ['Alex', 'Protect my focus']);
  });
}
