import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/integrations/apple_eventkit.dart';
import 'package:omi/integrations/apple_eventkit_import.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('omi/apple_eventkit_import_test');

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'imports EventKit evidence with explicit scope and stable times',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => [
              {
                'id': 'apple_reminders:reminder-1',
                'nativeId': 'reminder-1',
                'source': 'reminders',
                'provider': 'apple_eventkit',
                'title': 'Ship Omi',
                'notes': '',
                'calendar': 'Tasks',
                'dueAt': '2026-07-22T15:00:00Z',
                'occurredAt': '2026-07-21T10:00:00Z',
                'recordedAt': '2026-07-21T12:00:00Z',
                'isCompleted': false,
              },
            ],
          );
      final hub = _CaptureHub();
      final coordinator = AppleEventKitImportCoordinator(
        eventKit: AppleEventKitService(channel: channel, available: true),
        hub: hub,
        personId: 'person-1',
        requestId: () => 'request-1',
        recordedAt: (_, item) async => item.recordedAt.millisecondsSinceEpoch,
      );

      expect(await coordinator.import(AppleEventKitSource.reminders), 1);
      expect(hub.source, CaptureSource.appleReminders);
      expect(hub.ingestionKey, 'eventkit:reminders:reminder-1:1784635200000');
      expect(hub.occurredAtMs, 1784628000000);
      expect(hub.recordedAtMs, 1784635200000);
    },
  );

  test('reuses the first observation time for an unchanged revision', () async {
    var recordedAt = '2026-07-21T12:00:00Z';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => [
            {
              'id': 'apple_calendar:event-1',
              'nativeId': 'event-1',
              'source': 'calendar',
              'title': 'Ship Omi',
              'notes': '',
              'calendar': 'Work',
              'startAt': '2026-07-22T15:00:00Z',
              'endAt': '2026-07-22T16:00:00Z',
              'occurredAt': '2026-07-22T15:00:00Z',
              'recordedAt': recordedAt,
            },
          ],
        );
    final observations = <String, int>{};
    final hub = _CaptureHub();
    final coordinator = AppleEventKitImportCoordinator(
      eventKit: AppleEventKitService(channel: channel, available: true),
      hub: hub,
      personId: 'person-1',
      recordedAt: (personId, item) async => observations.putIfAbsent(
        '$personId:${item.id}:${item.memoryText}',
        () => item.recordedAt.millisecondsSinceEpoch,
      ),
    );

    await coordinator.import(AppleEventKitSource.calendar);
    final first = hub.recordedAtMs;
    recordedAt = '2026-07-21T13:00:00Z';
    await coordinator.import(AppleEventKitSource.calendar);

    expect(hub.recordedAtMs, first);
    expect(hub.ingestionKey, 'eventkit:calendar:event-1:$first');
  });
}

final class _CaptureHub implements NativeHub {
  CaptureSource? source;
  String? ingestionKey;
  int? occurredAtMs;
  int? recordedAtMs;

  @override
  void capture({
    required String requestId,
    required String ingestionKey,
    required CaptureSource source,
    required int occurredAtMs,
    required int recordedAtMs,
    String? text,
    String? application,
    String? windowTitle,
    TranscriptLocator? transcriptLocator,
  }) {
    this.source = source;
    this.ingestionKey = ingestionKey;
    this.occurredAtMs = occurredAtMs;
    this.recordedAtMs = recordedAtMs;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
