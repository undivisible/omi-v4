import 'package:shared_preferences/shared_preferences.dart';

abstract interface class OnboardingCompletionStore {
  Future<bool> isComplete(String uid);

  Future<void> complete(String uid);
}

final class PreferencesOnboardingCompletionStore
    implements OnboardingCompletionStore {
  static const _prefix = 'onboarding_complete_v1_';

  @override
  Future<bool> isComplete(String uid) async =>
      (await SharedPreferences.getInstance()).getBool('$_prefix$uid') == true;

  @override
  Future<void> complete(String uid) async {
    final saved = await (await SharedPreferences.getInstance()).setBool(
      '$_prefix$uid',
      true,
    );
    if (!saved) throw StateError('Onboarding completion was not saved');
  }
}

final class VolatileOnboardingCompletionStore
    implements OnboardingCompletionStore {
  final completedUids = <String>{};

  @override
  Future<bool> isComplete(String uid) async => completedUids.contains(uid);

  @override
  Future<void> complete(String uid) async => completedUids.add(uid);
}
