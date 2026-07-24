import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'demo_model_bridge.dart';

/// Which model, if any, is answering the demo's chat.
enum DemoModelTier {
  /// No model. The seeded replies answer, and the UI says so.
  scripted,

  /// The browser's own on-device model (Chrome's Prompt API). Nothing is
  /// downloaded and nothing leaves the machine.
  promptApi,

  /// transformers.js on WebGPU, running a small instruct model. Only ever
  /// reached from an explicit opt-in that named the download size first.
  webgpu,
}

/// Where the demo's answers are coming from, and what it is allowed to say
/// about them.
///
/// The rule this class exists to enforce: a reply is only ever described as
/// coming from a model when a model actually produced it. Every degrade —
/// no browser model, a refused download, a generation that failed halfway —
/// lands back on [DemoModelTier.scripted] and the label changes with it.
class DemoModel extends ChangeNotifier {
  DemoModel();

  static final DemoModel instance = DemoModel();

  DemoModelTier _tier = DemoModelTier.scripted;
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

  /// The name of the model the WebGPU tier would fetch, for the opt-in copy.
  String get downloadModel => _probe.model;

  int get downloadMb => _probe.downloadMb;

  /// True when the browser's built-in model is installed and will answer
  /// without fetching anything.
  bool get promptApiReady => _probe.promptApi == 'ready';

  /// True when the browser has the model available but would have to download
  /// it first. That is still a download, so it waits behind its own opt-in —
  /// the size is the browser's business, not ours, and it is shared with
  /// every other site rather than being ours to spend.
  bool get canOfferPromptApi =>
      _probe.promptApi == 'downloadable' &&
      _tier == DemoModelTier.scripted &&
      !_preparing;

  /// True only when the machine passed every capability check and the
  /// runtime is vendored on this origin. The opt-in is offered nowhere else.
  bool get canOfferWebgpu =>
      _probe.webgpu && _tier != DemoModelTier.webgpu && !_preparing;

  /// What the visitor is told, verbatim, about the current tier.
  String get label => switch (_tier) {
    DemoModelTier.promptApi => 'Your browser\'s built-in model, on-device',
    DemoModelTier.webgpu => '$downloadModel, on-device via WebGPU',
    DemoModelTier.scripted => 'Scripted preview — no model is running',
  };

  String get detail => switch (_tier) {
    DemoModelTier.promptApi =>
      'Chrome is answering with the model already installed on this machine. '
          'Nothing is downloaded and nothing is sent anywhere.',
    DemoModelTier.webgpu =>
      'A small instruct model you chose to download is running on this '
          'machine\'s GPU. Nothing you type is sent anywhere.',
    DemoModelTier.scripted =>
      'These answers come from a fixed set of notes in the page, not from a '
          'model. The tour is written to work this way.',
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
          'Your browser would not start its built-in model, so the tour '
          'stays scripted.';
    }
    notifyListeners();
  }

  /// The WebGPU opt-in. Only ever called from a button whose label already
  /// stated the download size.
  Future<void> enableWebgpu() async {
    if (_preparing || !_probe.webgpu) return;
    _preparing = true;
    _progress = 0;
    _failure = null;
    notifyListeners();
    final result = await prepareDemoModel('webgpu', (percent) {
      _progress = percent;
      notifyListeners();
    });
    _preparing = false;
    if (result == 'ready') {
      _tier = DemoModelTier.webgpu;
    } else {
      _failure = 'The model could not start here, so the tour stays scripted.';
    }
    notifyListeners();
  }

  /// Streams an answer from the active model, or null when there is no model
  /// to ask. A failure before the first token also returns null, so the
  /// caller can fall back to the scripted reply without having shown a
  /// half-finished sentence.
  Stream<String>? ask({
    required String system,
    required List<({String role, String text})> history,
    required String prompt,
  }) {
    if (_tier == DemoModelTier.scripted) return null;
    final payload = jsonEncode({
      'system': system,
      'history': [
        for (final turn in history) {'role': turn.role, 'text': turn.text},
      ],
      'prompt': prompt,
    });
    return askDemoModel(
      _tier == DemoModelTier.promptApi ? 'prompt-api' : 'webgpu',
      payload,
    );
  }

  void cancel() => cancelDemoModel();

  /// Called when a generation failed outright. The tour carries on scripted
  /// rather than leaving a dead chat behind.
  void degradeToScripted(Object error) {
    if (_tier == DemoModelTier.scripted) return;
    _tier = DemoModelTier.scripted;
    _failure =
        'The on-device model stopped answering, so the tour is scripted from '
        'here.';
    debugPrint('demo model degraded: $error');
    notifyListeners();
  }
}
