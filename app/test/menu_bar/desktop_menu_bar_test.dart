import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/menu_bar/desktop_menu_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('publishes the first Current and actual listening state', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('omi/menu_bar_test');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final currents = CurrentsController(CurrentsClient(_Transport()));
    final createdAt = DateTime.utc(2026, 7, 21, 12);
    CurrentCard current(String id, String title) => CurrentCard(
      item: CurrentItem.candidate(
        id: id,
        evidence: [
          CurrentEvidence(sourceId: 'memory-$id', reason: 'Commitment'),
        ],
        reason: 'Commitment',
        timing: CurrentTiming(surfaceAt: createdAt),
        confidence: .9,
        proposedNextStep: title,
        createdAt: createdAt,
      ).transitionTo(CurrentStatus.surfaced, at: createdAt),
      title: title,
      summary: title,
    );
    currents.items = [
      current('first', 'Finish the release'),
      current('second', 'Later task'),
    ];
    final menuBar = DesktopMenuBarController(
      currents: currents,
      isListening: () => true,
      isMeetingActive: () => false,
      onCapture: () async {},
      onToggleListening: () async {},
      onToggleMeeting: () async {},
      onOpenSettings: () {},
      channel: channel,
    );

    await menuBar.start();

    expect(calls.single.method, 'update');
    expect(calls.single.arguments, {
      'task': 'Finish the release',
      'listening': true,
      'meeting': false,
    });
    await menuBar.dispose();
  });

  test('strips markdown markers from the published Current title', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('omi/menu_bar_strip_test');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final currents = CurrentsController(CurrentsClient(_Transport()));
    final createdAt = DateTime.utc(2026, 7, 21, 12);
    currents.items = [
      CurrentCard(
        item: CurrentItem.candidate(
          id: 'first',
          evidence: [
            CurrentEvidence(sourceId: 'memory-first', reason: 'Commitment'),
          ],
          reason: 'Commitment',
          timing: CurrentTiming(surfaceAt: createdAt),
          confidence: .9,
          proposedNextStep: 'Finish the `release`',
          createdAt: createdAt,
        ).transitionTo(CurrentStatus.surfaced, at: createdAt),
        title: '**Finish** the `release`',
        summary: '**Finish** the `release`',
      ),
    ];
    final menuBar = DesktopMenuBarController(
      currents: currents,
      isListening: () => false,
      isMeetingActive: () => false,
      onCapture: () async {},
      onToggleListening: () async {},
      onToggleMeeting: () async {},
      onOpenSettings: () {},
      channel: channel,
    );

    await menuBar.start();

    expect(calls.single.arguments, {
      'task': 'Finish the release',
      'listening': false,
      'meeting': false,
    });
    await menuBar.dispose();
  });

  test('publishes meeting state and relays the menu-bar toggle', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('omi/menu_bar_meeting_test');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    var meeting = false;
    var toggles = 0;
    final menuBar = DesktopMenuBarController(
      currents: null,
      isListening: () => false,
      isMeetingActive: () => meeting,
      onCapture: () async {},
      onToggleListening: () async {},
      onToggleMeeting: () async {
        toggles += 1;
        meeting = !meeting;
      },
      onOpenSettings: () {},
      channel: channel,
    );

    await menuBar.start();
    expect(calls.single.arguments, {
      'task': null,
      'listening': false,
      'meeting': false,
    });

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(const MethodCall('toggleMeeting')),
          (_) {},
        );

    expect(toggles, 1);
    expect(calls.last.arguments, {
      'task': null,
      'listening': false,
      'meeting': true,
    });
    await menuBar.dispose();
  });
}

final class _Transport implements CurrentsTransport {
  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async =>
      const CurrentsResponse(statusCode: 200, body: {});
}
