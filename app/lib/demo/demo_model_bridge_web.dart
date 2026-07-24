import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';

import 'demo_model_bridge_stub.dart' show DemoModelProbe;

export 'demo_model_bridge_stub.dart' show DemoModelProbe;

/// The JS half of the bridge, served from `/hub/hub-llm.js` on the same origin
/// as the rest of the demo. It is absent if that script failed to load, in
/// which case every call here degrades to "no model".
_Llm? get _llm {
  final value = globalContext['omiDemoLlm'];
  return value.isA<JSObject>() ? value! as _Llm : null;
}

extension type _Llm._(JSObject _) implements JSObject {
  // Both of these resolve to a JS string, which is the one shape a promise
  // value cannot be unwrapped from reliably here. They are awaited for their
  // completion only, and the result is read back off the plain string
  // properties below.
  external JSPromise<JSAny?> probe();
  external void prepare(JSString tier, JSFunction onProgress);
  external String get last;
  external String get lastPrepare;
  external void startAsk(
    JSString tier,
    JSString payload,
    JSFunction onChunk,
    JSFunction onDone,
    JSFunction onError,
  );
  external void cancel();
}

/// Asks the bridge what this browser can run, retrying briefly.
///
/// The retry is not superstition: this runs during boot, and a probe that
/// lost a race with the script tag would otherwise pin the demo to the
/// scripted tier for the whole session.
Future<DemoModelProbe> probeDemoModels() async {
  for (var attempt = 0; attempt < 10; attempt++) {
    final llm = _llm;
    if (llm != null) {
      try {
        await llm.probe().toDart;
        final raw = llm.last;
        if (raw.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        final decoded = jsonDecode(raw) as Map<String, Object?>;
        return DemoModelProbe(
          promptApi: (decoded['promptApi'] as String?) ?? 'unsupported',
          webgpu: decoded['webgpu'] == true,
          model: (decoded['model'] as String?) ?? '',
          downloadMb: (decoded['downloadMb'] as num?)?.round() ?? 0,
        );
      } catch (error) {
        debugPrint('demo model probe failed: $error');
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return const DemoModelProbe();
}

Future<String> prepareDemoModel(
  String tier,
  void Function(int percent) onProgress,
) async {
  final llm = _llm;
  if (llm == null) return 'unsupported';
  // Started, then waited on by polling the result property. The promise these
  // calls return cannot be awaited reliably from here, and a tour that hangs
  // on an unresolvable future would never fall back to its scripted tier.
  try {
    llm.prepare(
      tier.toJS,
      ((JSNumber percent) => onProgress(percent.toDartInt)).toJS,
    );
  } catch (error) {
    return 'failed: $error';
  }
  final deadline = DateTime.now().add(const Duration(minutes: 12));
  while (DateTime.now().isBefore(deadline)) {
    final result = llm.lastPrepare;
    if (result.isNotEmpty) return result;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return 'failed: timed out';
}

Stream<String> askDemoModel(String tier, String payloadJson) {
  final llm = _llm;
  if (llm == null) return const Stream<String>.empty();
  final controller = StreamController<String>();
  void close() {
    if (!controller.isClosed) controller.close();
  }

  try {
    llm.startAsk(
      tier.toJS,
      payloadJson.toJS,
      ((String chunk) {
        if (!controller.isClosed) controller.add(chunk);
      }).toJS,
      (() => close()).toJS,
      ((String message) {
        if (!controller.isClosed) controller.addError(StateError(message));
        close();
      }).toJS,
    );
  } catch (error) {
    controller.addError(error);
    close();
  }
  return controller.stream;
}

void cancelDemoModel() {
  try {
    _llm?.cancel();
  } catch (_) {}
}
