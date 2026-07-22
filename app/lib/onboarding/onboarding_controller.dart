import 'package:flutter/foundation.dart';

enum OnboardingStage { introduction, access, scan, profile, use }

final class OnboardingController extends ChangeNotifier {
  OnboardingStage stage = OnboardingStage.introduction;
  int questionIndex = 0;
  String? validationMessage;

  final List<String> _answers = [];

  List<String> get answers => List.unmodifiable(_answers);

  void continueFromIntroduction() {
    stage = OnboardingStage.access;
    validationMessage = null;
    notifyListeners();
  }

  void completeAccess() {
    stage = OnboardingStage.scan;
    validationMessage = null;
    notifyListeners();
  }

  void completeScan() {
    if (stage != OnboardingStage.scan) return;
    stage = OnboardingStage.profile;
    notifyListeners();
  }

  bool submitAnswer(String value, {required int questionCount}) {
    final answer = value.trim();
    if (answer.isEmpty) {
      validationMessage = 'Tell Omi a little more before continuing.';
      notifyListeners();
      return false;
    }
    _answers.add(answer);
    validationMessage = null;
    if (questionIndex + 1 < questionCount) {
      questionIndex++;
    } else {
      stage = OnboardingStage.use;
    }
    notifyListeners();
    return true;
  }
}
