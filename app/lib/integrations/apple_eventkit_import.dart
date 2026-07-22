import '../native/native_hub.dart';
import 'apple_eventkit.dart';

final class AppleEventKitImportCoordinator {
  factory AppleEventKitImportCoordinator({
    required AppleEventKitService eventKit,
    required NativeHub hub,
    String Function()? requestId,
  }) => AppleEventKitImportCoordinator._(
    eventKit,
    hub,
    requestId ?? _defaultRequestId,
  );

  AppleEventKitImportCoordinator._(this._eventKit, this._hub, this._requestId);

  final AppleEventKitService _eventKit;
  final NativeHub _hub;
  final String Function() _requestId;

  Future<int> import(
    AppleEventKitSource source, {
    int limit = 200,
    int daysBack = 365,
    int daysForward = 30,
  }) async {
    final items = await _eventKit.read(
      source,
      limit: limit,
      daysBack: daysBack,
      daysForward: daysForward,
    );
    for (final item in items) {
      _hub.capture(
        requestId: _requestId(),
        ingestionKey:
            'eventkit:${item.nativeId}:${item.recordedAt.millisecondsSinceEpoch}',
        source: switch (item.source) {
          AppleEventKitSource.calendar => CaptureSource.appleCalendar,
          AppleEventKitSource.reminders => CaptureSource.appleReminders,
        },
        occurredAtMs: item.occurredAt.millisecondsSinceEpoch,
        recordedAtMs: item.recordedAt.millisecondsSinceEpoch,
        text: item.memoryText,
      );
    }
    return items.length;
  }

  static String _defaultRequestId() =>
      'eventkit-${DateTime.now().microsecondsSinceEpoch}';
}
