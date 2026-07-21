import 'package:flutter/foundation.dart';

enum OnboardingStage { introduction, profile, permissions }

final class OnboardingController extends ChangeNotifier {
  OnboardingStage stage = OnboardingStage.introduction;
  bool previewAcknowledged = false;
  int questionIndex = 0;
  String? validationMessage;

  final List<String> _answers = [];

  List<String> get answers => List.unmodifiable(_answers);

  bool get canContinueIntroduction => previewAcknowledged;

  void setPreviewAcknowledged(bool value) {
    previewAcknowledged = value;
    validationMessage = null;
    notifyListeners();
  }

  void continueFromIntroduction() {
    if (!previewAcknowledged) {
      validationMessage = 'Acknowledge the preview limits to continue.';
      notifyListeners();
      return;
    }
    stage = OnboardingStage.profile;
    validationMessage = null;
    notifyListeners();
  }

  bool submitAnswer(String value, {required int questionCount}) {
    final answer = value.trim();
    if (answer.isEmpty) {
      validationMessage = 'Enter an answer before continuing.';
      notifyListeners();
      return false;
    }
    _answers.add(answer);
    validationMessage = null;
    if (questionIndex + 1 < questionCount) {
      questionIndex++;
    } else {
      stage = OnboardingStage.permissions;
    }
    notifyListeners();
    return true;
  }
}
