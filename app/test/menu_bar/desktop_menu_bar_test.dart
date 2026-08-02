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
      onOpenInput: () async => null,
      onToggleLiveConversation: () async => null,
      onToggleMeeting: () async => null,
      onOpenSettings: () {},
      channel: channel,
    );

    await menuBar.start();

    expect(calls.single.method, 'update');
    expect(calls.single.arguments, {
      'task': 'Finish the release',
      'listening': true,
      'meeting': false,
      'notice': null,
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
      onOpenInput: () async => null,
      onToggleLiveConversation: () async => null,
      onToggleMeeting: () async => null,
      onOpenSettings: () {},
      channel: channel,
    );

    await menuBar.start();

    expect(calls.single.arguments, {
      'task': 'Finish the release',
      'listening': false,
      'meeting': false,
      'notice': null,
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
      onOpenInput: () async => null,
      onToggleLiveConversation: () async => null,
      onToggleMeeting: () async {
        toggles += 1;
        meeting = !meeting;
        return null;
      },
      onOpenSettings: () {},
      channel: channel,
    );

    await menuBar.start();
    expect(calls.single.arguments, {
      'task': null,
      'listening': false,
      'meeting': false,
      'notice': null,
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
      'notice': null,
    });
    await menuBar.dispose();
  });

  test('live conversation and text input are separate menu actions', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('omi/menu_bar_separate_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    var inputs = 0;
    var conversations = 0;
    final menuBar = DesktopMenuBarController(
      currents: null,
      isListening: () => false,
      isMeetingActive: () => false,
      onOpenInput: () async {
        inputs += 1;
        return null;
      },
      onToggleLiveConversation: () async {
        conversations += 1;
        return null;
      },
      onToggleMeeting: () async => null,
      onOpenSettings: () {},
      channel: channel,
    );
    await menuBar.start();

    Future<void> invoke(String method) => TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall(method)),
          (_) {},
        );

    await invoke('openInput');
    expect(inputs, 1);
    expect(conversations, 0);

    await invoke('toggleLiveConversation');
    expect(inputs, 1);
    expect(conversations, 1);

    await menuBar.dispose();
  });

  test('publishes why an action failed instead of doing nothing', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('omi/menu_bar_notice_test');
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
    String? reason = 'Native services are not connected.';
    final menuBar = DesktopMenuBarController(
      currents: null,
      isListening: () => false,
      isMeetingActive: () => false,
      onOpenInput: () async => null,
      onToggleLiveConversation: () async => null,
      onToggleMeeting: () async => reason,
      onOpenSettings: () {},
      channel: channel,
    );
    await menuBar.start();

    Future<void> toggle() => TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(const MethodCall('toggleMeeting')),
          (_) {},
        );

    await toggle();
    expect(menuBar.notice, 'Native services are not connected.');
    expect(
      calls.last.arguments,
      containsPair('notice', 'Native services are not connected.'),
    );

    reason = null;
    await toggle();
    expect(menuBar.notice, isNull);
    expect(calls.last.arguments, containsPair('notice', null));

    await menuBar.dispose();
  });
}

final class _Transport implements CurrentsTransport {
  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async =>
      const CurrentsResponse(statusCode: 200, body: {});
}
