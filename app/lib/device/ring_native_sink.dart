import 'dart:async';

import '../native/native_hub.dart';
import 'ring_backlog.dart';

final class NativeDurableRingSink implements DurableRingSink {
  NativeDurableRingSink(this.hub);

  final NativeHub hub;
  var _sequence = 0;

  @override
  Future<void> importRange(DurableRingRange range) async {
    if (!hub.available) throw StateError('native WAL is unavailable');
    final requestId = 'ring-import-${_sequence++}-${range.sourceId}';
    final result = hub.events
        .where((event) => event is NativeEventCaptureWalState)
        .cast<NativeEventCaptureWalState>()
        .map((event) => event.value)
        .firstWhere((state) => state.requestId == requestId);
    hub.importRingRange(
      requestId: requestId,
      sourceId: range.sourceId,
      deviceId: range.deviceId,
      startedAtMs: range.startedAtMs,
      frames: range.frames,
    );
    final state = await result.timeout(const Duration(seconds: 30));
    if (state.lastError case final error?) throw StateError(error);
  }
}
