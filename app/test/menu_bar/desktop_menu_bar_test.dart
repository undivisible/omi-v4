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
      onCapture: () async {},
      onToggleListening: () async {},
      onOpenSettings: () {},
      channel: channel,
    );

    await menuBar.start();

    expect(calls.single.method, 'update');
    expect(calls.single.arguments, {
      'task': 'Finish the release',
      'listening': true,
    });
    await menuBar.dispose();
  });
}

final class _Transport implements CurrentsTransport {
  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async =>
      const CurrentsResponse(statusCode: 200, body: {});
}
