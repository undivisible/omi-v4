import 'package:flutter/foundation.dart';

/// Lets the demo's tour put a message into the real composer.
///
/// The tour's chips are questions the visitor asks, so they have to go through
/// the chat screen's own send path — the same path the keyboard uses — rather
/// than being drawn as fake transcript. The chat screen attaches one handler
/// while it is mounted, and only in the demo build: outside it, `omiDemoMode`
/// is false and the attach call is compiled away.
class DemoPromptBus {
  DemoPromptBus();

  static final DemoPromptBus instance = DemoPromptBus();

  ValueChanged<String>? _handler;

  /// True while a composer is listening. The tour hides its chips otherwise.
  bool get attached => _handler != null;

  final ValueNotifier<int> attachments = ValueNotifier(0);

  void attach(ValueChanged<String> handler) {
    _handler = handler;
    attachments.value += 1;
  }

  void detach(ValueChanged<String> handler) {
    if (_handler != handler) return;
    _handler = null;
    attachments.value += 1;
  }

  void send(String prompt) => _handler?.call(prompt);
}
