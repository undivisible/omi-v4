import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/integrations/apple_eventkit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('omi/apple_eventkit_test');
  final service = AppleEventKitService(channel: channel, available: true);

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('reads bounded EventKit items with stable provenance', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'read');
          expect((call.arguments as Map)['limit'], 2500);
          return [
            {
              'id': 'apple_calendar:event-1',
              'nativeId': 'event-1',
              'source': 'calendar',
              'provider': 'apple_eventkit',
              'title': 'Design review',
              'notes': 'Bring mockups',
              'calendar': 'Work',
              'startAt': '2026-07-21T14:00:00Z',
              'endAt': '2026-07-21T15:00:00Z',
              'occurredAt': '2026-07-21T14:00:00Z',
              'recordedAt': '2026-07-21T13:00:00Z',
              'isAllDay': false,
              'location': 'Studio',
            },
          ];
        });

    final items = await service.read(AppleEventKitSource.calendar, limit: 9999);

    expect(items.single.id, 'apple_calendar:event-1');
    expect(items.single.occurredAt, DateTime.utc(2026, 7, 21, 14));
    expect(items.single.recordedAt, DateTime.utc(2026, 7, 21, 13));
    expect(items.single.memoryText, contains('Bring mockups'));
  });
}
