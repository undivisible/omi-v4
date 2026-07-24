/// Resolves the demo's model bridge: the real one on the web target, a stub
/// that reports "no model here" everywhere else. Only the web build ever has
/// a browser to ask.
library;

export 'demo_model_bridge_stub.dart'
    if (dart.library.js_interop) 'demo_model_bridge_web.dart';
