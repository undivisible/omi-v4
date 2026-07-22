import 'package:shared_preferences/shared_preferences.dart';

import '../api/worker_http.dart';

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

final class WorkerOnboardingCompletionStore
    implements OnboardingCompletionStore {
  const WorkerOnboardingCompletionStore(this._client);

  final WorkerHttpClient _client;

  @override
  Future<bool> isComplete(String uid) async {
    final response = await _client.sendWithSession(
      method: 'GET',
      path: '/v1/profile/onboarding',
    );
    if (response.session.uid != uid) {
      throw const WorkerAuthenticationException(
        'Account authority changed while reading onboarding state',
      );
    }
    final body = response.body;
    if (response.statusCode != 200 || body is! Map<String, Object?>) {
      throw const WorkerResponseException(
        'Worker returned invalid onboarding state',
      );
    }
    return body['complete'] == true;
  }

  @override
  Future<void> complete(String uid) async {
    final response = await _client.sendWithSession(
      method: 'PUT',
      path: '/v1/profile/onboarding',
      body: {'complete': true},
    );
    if (response.session.uid != uid) {
      throw const WorkerAuthenticationException(
        'Account authority changed while saving onboarding state',
      );
    }
    final body = response.body;
    if (response.statusCode != 200 ||
        body is! Map<String, Object?> ||
        body['complete'] != true) {
      throw const WorkerResponseException(
        'Onboarding completion was not saved to the account',
      );
    }
  }
}

final class LayeredOnboardingCompletionStore
    implements OnboardingCompletionStore {
  const LayeredOnboardingCompletionStore({
    required this.local,
    required this.remote,
  });

  final OnboardingCompletionStore local;
  final OnboardingCompletionStore remote;

  @override
  Future<bool> isComplete(String uid) async {
    try {
      if (await local.isComplete(uid)) return true;
    } catch (_) {}
    final bool remoteComplete;
    try {
      remoteComplete = await remote.isComplete(uid);
    } catch (_) {
      return false;
    }
    if (remoteComplete) {
      try {
        await local.complete(uid);
      } catch (_) {}
    }
    return remoteComplete;
  }

  @override
  Future<void> complete(String uid) async {
    await local.complete(uid);
    try {
      await remote.complete(uid);
    } catch (_) {
      try {
        await remote.complete(uid);
      } catch (_) {}
    }
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
