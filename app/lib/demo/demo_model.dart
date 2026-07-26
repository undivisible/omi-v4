import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'demo_model_bridge.dart';

/// Which model, if any, is answering the demo's chat.
enum DemoModelTier {
  /// No model. Chat stays unavailable, and the UI says so.
  unavailable,

  /// The browser's own on-device model (Chrome's Prompt API). Nothing is
  /// downloaded and nothing leaves the machine.
  promptApi,
}

/// Where the demo's answers are coming from, and what it is allowed to say
/// about them.
///
/// The rule this class exists to enforce: a reply is only ever described as
/// coming from a model when a model actually produced it. Every degrade lands
/// on [DemoModelTier.unavailable] and the label changes with it.
class DemoModel extends ChangeNotifier {
  DemoModel();

  static final DemoModel instance = DemoModel();

  DemoModelTier _tier = DemoModelTier.unavailable;
  DemoModelProbe _probe = const DemoModelProbe();
  bool _probed = false;
  bool _preparing = false;
  int _progress = 0;
  String? _failure;

  DemoModelTier get tier => _tier;

  bool get probed => _probed;

  bool get preparing => _preparing;

  int get progress => _progress;

  String? get failure => _failure;

  /// True when the browser's built-in model is installed and will answer
  /// without fetching anything.
  bool get promptApiReady => _probe.promptApi == 'ready';

  /// True when the browser has the model available but would have to download
  /// it first. That is still a download, so it waits behind its own opt-in —
  /// the size is the browser's business, not ours, and it is shared with
  /// every other site rather than being ours to spend.
  bool get canOfferPromptApi =>
      _probe.promptApi == 'downloadable' &&
      _tier == DemoModelTier.unavailable &&
      !_preparing;

  /// What the visitor is told, verbatim, about the current tier.
  String get label => switch (_tier) {
    DemoModelTier.promptApi => 'Your browser\'s Prompt API, on-device',
    DemoModelTier.unavailable => 'Prompt API unavailable',
  };

  String get detail => switch (_tier) {
    DemoModelTier.promptApi =>
      'Your browser is answering with the model installed on this machine. '
          'Nothing is downloaded and nothing is sent anywhere.',
    DemoModelTier.unavailable =>
      'This browser does not provide the on-device Prompt API. Explore the '
          'guided hub; chat replies are unavailable here.',
  };

  /// Asks the browser what it can run. Never downloads anything: the only
  /// tier adopted here is the one that is already on the machine.
  Future<void> resolve() async {
    if (_probed) return;
    _probed = true;
    _probe = await probeDemoModels();
    notifyListeners();
    if (!promptApiReady) return;
    if (await prepareDemoModel('prompt-api', (_) {}) == 'ready') {
      _tier = DemoModelTier.promptApi;
    }
    notifyListeners();
  }

  /// The Prompt API opt-in, for the case where the browser has the model
  /// available but not yet installed.
  Future<void> enablePromptApi() async {
    if (_preparing || _probe.promptApi != 'downloadable') return;
    _preparing = true;
    _failure = null;
    notifyListeners();
    final result = await prepareDemoModel('prompt-api', (percent) {
      _progress = percent;
      notifyListeners();
    });
    _preparing = false;
    if (result == 'ready') {
      _tier = DemoModelTier.promptApi;
    } else {
      _failure =
          'Your browser would not start its built-in model, so chat remains '
          'unavailable here.';
    }
    notifyListeners();
  }

  /// Streams an answer from the active model, or null when there is no model
  /// to ask.
  Stream<String>? ask({
    required String system,
    required List<({String role, String text})> history,
    required String prompt,
  }) {
    if (_tier != DemoModelTier.promptApi) return null;
    final payload = jsonEncode({
      'system': system,
      'history': [
        for (final turn in history) {'role': turn.role, 'text': turn.text},
      ],
      'prompt': prompt,
    });
    return askDemoModel('prompt-api', payload);
  }

  void cancel() => cancelDemoModel();

  void startNewConversation() => resetDemoModel();

  /// Called when a generation failed outright.
  void degradeToUnavailable(Object error) {
    if (_tier == DemoModelTier.unavailable) return;
    _tier = DemoModelTier.unavailable;
    _failure =
        'The on-device model stopped answering, so chat is unavailable here.';
    debugPrint('demo model degraded: $error');
    notifyListeners();
  }
}
