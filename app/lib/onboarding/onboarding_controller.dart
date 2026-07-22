import 'package:flutter/foundation.dart';

enum OnboardingStage { introduction, access, scan, profile, use }

final class OnboardingController extends ChangeNotifier {
  OnboardingStage stage = OnboardingStage.introduction;

  /// True once the "Already have an account?" path has been taken. A
  /// returning user already has a profile and memory on the backend, so
  /// completing access skips the fresh on-device scan and profile steps and
  /// goes straight to the short tutorial.
  bool returningUser = false;

  void continueFromIntroduction() {
    returningUser = false;
    stage = OnboardingStage.access;
    notifyListeners();
  }

  /// Entry point for "Already have an account?": login screen ->
  /// permissions screen (the existing access stage covers both), then
  /// straight to the tutorial, skipping the scan/profile steps.
  void beginReturningUserFlow() {
    returningUser = true;
    stage = OnboardingStage.access;
    notifyListeners();
  }

  void completeAccess() {
    stage = returningUser ? OnboardingStage.use : OnboardingStage.scan;
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
