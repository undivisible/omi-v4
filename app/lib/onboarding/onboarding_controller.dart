import 'package:flutter/foundation.dart';

enum OnboardingStage { introduction, access, scan, profile, use }

final class OnboardingController extends ChangeNotifier {
  OnboardingStage stage = OnboardingStage.introduction;

  void continueFromIntroduction() {
    stage = OnboardingStage.access;
    notifyListeners();
  }

  void completeAccess() {
    stage = OnboardingStage.scan;
    notifyListeners();
  }

  void completeScan() {
    if (stage != OnboardingStage.scan) return;
    stage = OnboardingStage.profile;
    notifyListeners();
  }

  void completeProfile() {
    if (stage != OnboardingStage.profile) return;
    stage = OnboardingStage.use;
    notifyListeners();
  }
}
