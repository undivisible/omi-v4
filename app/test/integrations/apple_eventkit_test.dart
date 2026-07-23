import 'package:flutter/foundation.dart';
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

  test('an unavailable service never touches the platform channel', () async {
    final unavailable = AppleEventKitService(
      channel: channel,
      available: false,
    );
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          invoked = true;
          return null;
        });

    expect(
      await unavailable.status(AppleEventKitSource.calendar),
      AppleEventKitAuthorization.unavailable,
    );
    expect(
      await unavailable.request(AppleEventKitSource.reminders),
      AppleEventKitAuthorization.unavailable,
    );
    expect(await unavailable.read(AppleEventKitSource.calendar), isEmpty);
    expect(
      await unavailable.upsertItem(
        source: AppleEventKitSource.reminders,
        currentId: 'task-1',
        title: 'Ship Omi',
        notes: '',
      ),
      isNull,
    );
    await unavailable.completeItem(AppleEventKitSource.reminders, 'native-1');
    await unavailable.removeItem(AppleEventKitSource.reminders, 'native-1');
    expect(invoked, isFalse);
  });

  test('authorization states map from the native wire names', () async {
    const wire = {
      'not_determined': AppleEventKitAuthorization.notDetermined,
      'restricted': AppleEventKitAuthorization.restricted,
      'denied': AppleEventKitAuthorization.denied,
      'write_only': AppleEventKitAuthorization.writeOnly,
      'full_access': AppleEventKitAuthorization.fullAccess,
      'something-else': AppleEventKitAuthorization.unavailable,
    };

    for (final entry in wire.entries) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => {'status': entry.key},
          );

      expect(
        await service.status(AppleEventKitSource.calendar),
        entry.value,
        reason: entry.key,
      );
      expect(
        await service.request(AppleEventKitSource.calendar),
        entry.value,
        reason: entry.key,
      );
    }
  });

  test('a native reply without a status is treated as unavailable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);

    expect(
      await service.status(AppleEventKitSource.reminders),
      AppleEventKitAuthorization.unavailable,
    );
    expect(
      await service.request(AppleEventKitSource.reminders),
      AppleEventKitAuthorization.unavailable,
    );
  });

  test('read windows are clamped to a sane range', () async {
    late Map<Object?, Object?> arguments;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          arguments = call.arguments as Map<Object?, Object?>;
          return null;
        });

    expect(
      await service.read(
        AppleEventKitSource.reminders,
        limit: -5,
        daysBack: -1,
        daysForward: 99999,
      ),
      isEmpty,
    );
    expect(arguments['limit'], 1);
    expect(arguments['daysBack'], 0);
    expect(arguments['daysForward'], 3650);
  });

  test('a native failure during read surfaces to the caller', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'denied'),
        );

    await expectLater(
      service.read(AppleEventKitSource.calendar),
      throwsA(isA<PlatformException>()),
    );
  });

  test('writes send UTC timestamps and return the native identity', () async {
    late Map<Object?, Object?> arguments;
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          arguments = call.arguments as Map<Object?, Object?>;
          return {'nativeId': 'reminder-9'};
        });

    final nativeId = await service.upsertItem(
      source: AppleEventKitSource.reminders,
      currentId: 'task-1',
      title: 'Ship Omi',
      notes: 'with tests',
      dueAt: DateTime.utc(2026, 7, 22, 15).toLocal(),
    );
    await service.completeItem(AppleEventKitSource.reminders, 'reminder-9');
    await service.removeItem(AppleEventKitSource.reminders, 'reminder-9');

    expect(nativeId, 'reminder-9');
    expect(methods, ['upsertItem', 'completeItem', 'removeItem']);
    expect(arguments['nativeId'], 'reminder-9');
  });

  test('an upsert reply without a native id yields null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => <String, Object?>{});

    expect(
      await service.upsertItem(
        source: AppleEventKitSource.calendar,
        currentId: 'task-1',
        title: 'Ship Omi',
        notes: '',
      ),
      isNull,
    );
  });

  test('optional item fields fall back rather than crashing', () {
    final item = AppleEventKitItem.fromMap(const {
      'id': 'apple_reminders:reminder-1',
      'nativeId': 'reminder-1',
      'source': 'reminders',
      'title': 'Ship Omi',
      'notes': '',
      'calendar': 'Tasks',
      'occurredAt': '2026-07-21T10:00:00Z',
      'recordedAt': '2026-07-21T12:00:00Z',
      'startAt': null,
      'dueAt': 7,
    });

    expect(item.startAt, isNull);
    expect(item.dueAt, isNull);
    expect(item.location, isEmpty);
    expect(item.isAllDay, isFalse);
    expect(item.isCompleted, isFalse);
    expect(item.memoryText, 'Apple Reminder: Ship Omi');
  });

  test('a malformed native row is rejected instead of half-decoded', () {
    expect(
      () => AppleEventKitItem.fromMap(const {
        'id': 'apple_calendar:event-1',
        'nativeId': 'event-1',
        'source': 'telepathy',
        'title': 'Ship Omi',
        'notes': '',
        'calendar': 'Work',
        'occurredAt': '2026-07-21T10:00:00Z',
        'recordedAt': '2026-07-21T12:00:00Z',
      }),
      throwsArgumentError,
    );
    expect(
      () => AppleEventKitItem.fromMap(const {
        'id': 'apple_calendar:event-1',
        'nativeId': 'event-1',
        'source': 'calendar',
        'title': 'Ship Omi',
        'notes': '',
        'calendar': 'Work',
        'occurredAt': 'not-a-date',
        'recordedAt': '2026-07-21T12:00:00Z',
      }),
      throwsFormatException,
    );
    expect(
      () => AppleEventKitItem.fromMap(const {
        'id': 'apple_calendar:event-1',
        'source': 'calendar',
        'title': 'Ship Omi',
        'notes': '',
        'calendar': 'Work',
        'occurredAt': '2026-07-21T10:00:00Z',
        'recordedAt': '2026-07-21T12:00:00Z',
      }),
      throwsA(isA<TypeError>()),
    );
  });

  test('availability defaults to the Apple platforms only', () {
    final detected = AppleEventKitService(channel: channel);

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(detected.available, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(detected.available, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(detected.available, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });
}
